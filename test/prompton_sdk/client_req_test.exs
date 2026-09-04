defmodule PromptOnSDK.Client.ReqTest do
  use ExUnit.Case, async: true

  alias PromptOnSDK.Client.Req, as: Client
  alias PromptOnSDK.Config

  # Req's `adapter:` option (a module) intercepts requests without a real socket (this also verifies
  # that the `http:` settings are passed to Req.new unchanged).
  # Requests run in the calling process, so each test hands its response function over through the
  # process dictionary.
  defmodule Adapter do
    def run(request), do: Process.get(:req_adapter_fun).(request)
  end

  defp config(adapter_fun) do
    Process.put(:req_adapter_fun, adapter_fun)

    Config.load(
      api_key: "ptn_production_secret",
      base_url: "https://prompton.test/api/v1/",
      http: [receive_timeout: 123, adapter: Adapter]
    )
  end

  defp header(req, name), do: Req.Request.get_header(req, name)

  test "fetch_snapshot sends Bearer + If-None-Match, keeps raw body, returns etag/last-modified" do
    test_pid = self()

    adapter = fn req ->
      send(test_pid, {:req, req})

      resp =
        Req.Response.new(status: 200, body: ~s({"schema_version":3}))
        |> Req.Response.put_header("etag", ~s("abc"))
        |> Req.Response.put_header("last-modified", "Mon, 18 Aug 2026 09:12:03 GMT")
        |> Req.Response.put_header("content-type", "application/json")

      {req, resp}
    end

    assert {:ok,
            %{
              status: 200,
              body: ~s({"schema_version":3}),
              etag: ~s("abc"),
              last_modified: "Mon, 18 Aug 2026 09:12:03 GMT"
            }} =
             Client.fetch_snapshot(config(adapter), ~s("old"), receive_timeout: 3_000)

    assert_received {:req, req}
    # The environment is set by the query, not by the key (2026-09-01)
    assert URI.to_string(req.url) ==
             "https://prompton.test/api/v1/snapshot?environment=production"

    assert req.method == :get
    assert header(req, "authorization") == ["Bearer ptn_production_secret"]
    assert header(req, "if-none-match") == [~s("old")]
    assert header(req, "accept") == ["application/json"]
    assert [ua] = header(req, "user-agent")
    assert ua =~ "prompton_sdk/"
    assert req.options[:retry] == false
    assert req.options[:receive_timeout] == 3_000
    assert req.options[:decode_body] == false
  end

  test "fetch_snapshot 304 and other statuses; transport errors" do
    assert {:ok, %{status: 304}} =
             Client.fetch_snapshot(
               config(fn req -> {req, Req.Response.new(status: 304)} end),
               "x",
               []
             )

    assert {:ok, %{status: 401, body: "nope"}} =
             Client.fetch_snapshot(
               config(fn req -> {req, Req.Response.new(status: 401, body: "nope")} end),
               nil,
               []
             )

    assert {:error, %Req.TransportError{reason: :timeout}} =
             Client.fetch_snapshot(
               config(fn req -> {req, %Req.TransportError{reason: :timeout}} end),
               nil,
               []
             )
  end

  test "post_generations / post_feedback send JSON envelopes and flatten headers" do
    test_pid = self()

    adapter = fn req ->
      send(test_pid, {:req, req})

      resp =
        Req.Response.new(status: 429, body: ~s({"error":"slow down"}))
        |> Req.Response.put_header("retry-after", "3")
        |> Req.Response.put_header("content-type", "application/json")

      {req, resp}
    end

    assert {:ok,
            %{status: 429, body: %{"error" => "slow down"}, headers: %{"retry-after" => "3"}}} =
             Client.post_generations(config(adapter), [%{"id" => "g1"}])

    assert_received {:req, req}
    assert req.method == :post
    assert URI.to_string(req.url) == "https://prompton.test/api/v1/generations"
    assert Jason.decode!(req.body) == %{"generations" => [%{"id" => "g1"}]}
    assert header(req, "content-type") == ["application/json"]
    assert req.options[:receive_timeout] == 123

    assert {:ok, %{status: 429}} =
             Client.post_feedback(config(adapter), [
               %{"generation_id" => "g1", "kind" => "thumbs"}
             ])

    assert_received {:req, req}
    assert URI.to_string(req.url) == "https://prompton.test/api/v1/feedback"

    assert Jason.decode!(req.body) == %{
             "feedback" => [%{"generation_id" => "g1", "kind" => "thumbs"}]
           }
  end

  test "post_* pass 5xx bodies and Retry-After through unchanged (503 → Buffer waits like 429)" do
    adapter = fn req ->
      resp =
        Req.Response.new(
          status: 503,
          body: ~s({"error":{"code":"unavailable","message":"try later","details":{}}})
        )
        |> Req.Response.put_header("retry-after", "5")
        |> Req.Response.put_header("content-type", "application/json")

      {req, resp}
    end

    assert {:ok,
            %{
              status: 503,
              body: %{"error" => %{"code" => "unavailable"}},
              headers: %{"retry-after" => "5"}
            }} = Client.post_generations(config(adapter), [%{"id" => "g1"}])

    # 413 (the parser limit) also passes status and body through unchanged; the Buffer splits
    # the batch
    adapter_413 = fn req ->
      {req,
       Req.Response.new(status: 413, body: ~s({"error":{"code":"payload_too_large"}}))
       |> Req.Response.put_header("content-type", "application/json")}
    end

    assert {:ok, %{status: 413, body: %{"error" => %{"code" => "payload_too_large"}}}} =
             Client.post_feedback(config(adapter_413), [%{"generation_id" => "g1"}])
  end

  test "base/1 without base_url raises; without api_key omits auth" do
    assert_raise ArgumentError, ~r/base_url/, fn -> Client.base(Config.load([])) end
    req = Client.base(Config.load(base_url: "https://x/api/v1"))
    assert header(req, "authorization") == []
  end
end
