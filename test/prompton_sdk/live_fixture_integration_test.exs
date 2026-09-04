defmodule PromptOnSDK.LiveFixtureIntegrationTest do
  @moduledoc """
  Real PromptOn fixture-server integration.

  Skips unless `PTN_API_KEY` is set. With a key, it talks to
  `PTN_HOST` (default `http://localhost:4000`) under `/api/v1`.
  """

  use ExUnit.Case, async: false

  alias PromptOnSDK.{Client, Config, Result, UseCase}
  alias PromptOnSDK.Snapshot.Store

  @moduletag :live_fixture

  unless System.get_env("PTN_API_KEY") do
    @moduletag skip:
                 "set PTN_API_KEY to run live fixture integration against PTN_HOST (default http://localhost:4000)"
  end

  setup do
    for {key, _} <- Application.get_all_env(:prompton_sdk) do
      Application.delete_env(:prompton_sdk, key)
    end

    Config.erase()
    Store.erase()

    on_exit(fn ->
      Config.erase()
      Store.erase()

      for {key, _} <- Application.get_all_env(:prompton_sdk) do
        Application.delete_env(:prompton_sdk, key)
      end
    end)

    opts = live_opts()
    start_supervised!({PromptOnSDK, opts})
    assert :ok = PromptOnSDK.refresh_use_case_document()

    %{config: Config.load(opts)}
  end

  test "GET /use-cases drives use_case/messages/text and remote prompt errors", %{
    config: config
  } do
    assert {:ok, %UseCase{} = use_case} =
             PromptOnSDK.use_case("greeting", prompt: "ko")

    assert use_case.source == :remote
    assert use_case.prompt == "ko"
    assert "ko" in use_case.prompt_names

    assert {:ok,
            [
              %{role: "system", content: system},
              %{role: "user", content: user}
            ]} =
             PromptOnSDK.messages(use_case, %{name: "아다"})

    assert system =~ "친절한 인사 도우미"
    assert user == "아다님에게 인사해줘."

    assert {:ok, text_use_case} = PromptOnSDK.use_case("summarize")
    assert {:ok, text} = PromptOnSDK.text(text_use_case, %{items: ["alpha", "beta"]})
    assert text =~ "- alpha"
    assert text =~ "- beta"

    assert PromptOnSDK.use_case("does_not_exist") == {:error, :unknown_use_case}

    assert PromptOnSDK.use_case("greeting", prompt: "does_not_exist") ==
             {:error, :unknown_prompt}

    assert {:ok, %{status: 200, body: remote}} =
             post_prompt(config, "greeting", %{
               "prompt" => "ko",
               "variables" => %{"name" => "아다"}
             })

    assert remote["key"] == "greeting"
    assert remote["source"] == "remote"
    assert get_in(remote, ["messages", Access.at(0), "content"]) =~ "친절한 인사 도우미"
    assert get_in(remote, ["messages", Access.at(1), "content"]) == "아다님에게 인사해줘."
    assert remote["prompt"] == "ko"
    assert is_binary(remote["prompt_version"]["id"])

    assert {:ok, %{status: status, body: body}} =
             post_prompt(config, "does_not_exist", %{"variables" => %{}})

    assert status in [404, 422]
    assert get_in(body, ["error", "code"]) == "not_found"
    assert get_in(body, ["error", "details", "key"]) == "does_not_exist"

    assert {:ok, %{status: status, body: body}} =
             post_prompt(config, "greeting", %{
               "prompt" => "does_not_exist",
               "variables" => %{"name" => "아다"}
             })

    assert status in [404, 422]
    assert get_in(body, ["error", "details", "reason"]) == "unknown_prompt"
    assert get_in(body, ["error", "details", "key"]) == "greeting"
    assert get_in(body, ["error", "details", "prompt_names"]) == ["default", "ko"]
  end

  test "POST /logs accepts the first live fixture log and reports duplicate resend", %{
    config: config
  } do
    assert {:ok, %UseCase{} = use_case} = PromptOnSDK.use_case("greeting")

    log = %{
      "id" => PromptOnSDK.log_id(),
      "use_case" => use_case.key,
      "kind" => "chat",
      "model" => use_case.model,
      "provider" => to_string(use_case.provider || :other),
      "status" => "ok",
      "started_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "deployment_id" => use_case.deployment.id,
      "deployment_revision" => use_case.deployment.revision,
      "prompt" => use_case.prompt,
      "prompt_version_id" => use_case.prompt_version && use_case.prompt_version.id,
      "model_id" => use_case.model_id,
      "source" => "remote",
      "output" => %{"content" => "live fixture integration"},
      "finish_reason" => "stop",
      "stop_kind" => "stop",
      "latency_ms" => 1,
      "usage" => %{"cost_source" => "unknown"},
      "sdk" => %{"name" => "prompton_sdk", "version" => PromptOnSDK.version()}
    }

    assert {:ok, %{status: 202, body: first}} = Client.Req.post_logs(config, [log])
    assert first["accepted"] == 1
    assert first["duplicates"] == 0
    assert first["rejected"] == []

    assert {:ok, %{status: 202, body: second}} = Client.Req.post_logs(config, [log])
    assert second["accepted"] == 0
    assert second["duplicates"] == 1
    assert second["rejected"] == []
  end

  test "messages(prompt: name) feeds the next track/3 log evidence once" do
    assert {:ok, default_use_case} = PromptOnSDK.use_case("greeting")

    assert {:ok, msgs} =
             PromptOnSDK.messages(
               default_use_case,
               %{name: "아다"},
               prompt: "ko"
             )

    result = %Result{
      content: "ok",
      usage: %{input_tokens: 1, output_tokens: 1},
      cost_source: :unknown
    }

    assert {:ok, ^result} =
             PromptOnSDK.track(
               default_use_case,
               %{id: PromptOnSDK.log_id(), input_messages: msgs},
               fn ->
                 {:ok, result}
               end
             )

    assert {:ok, 0} = PromptOnSDK.Buffer.flush(10_000)
  end

  defp live_opts do
    [
      mode: :live,
      api_key: System.fetch_env!("PTN_API_KEY"),
      base_url: base_url(),
      environment: System.get_env("PTN_ENVIRONMENT", "production"),
      disk_cache: nil,
      bundle: nil,
      poll_interval: 60_000,
      log: [flush_interval: 50, flush_size: 1, flush_bytes: 1_000_000, max_buffer: 100],
      http: [receive_timeout: 10_000]
    ]
  end

  defp base_url do
    host =
      System.get_env("PTN_HOST", "http://localhost:4000")
      |> String.trim_trailing("/")

    if String.ends_with?(host, "/api/v1") do
      host
    else
      host <> "/api/v1"
    end
  end

  defp post_prompt(config, key, body) do
    config
    |> Client.Req.base()
    |> Req.post(
      url: "/use-cases/#{key}/prompt",
      params: [environment: config.environment],
      json: body
    )
    |> case do
      {:ok, %Req.Response{status: status, body: body}} -> {:ok, %{status: status, body: body}}
      {:error, reason} -> {:error, reason}
    end
  end
end
