defmodule PromptOnSDK.Client.Req do
  @moduledoc """
  Default implementation of `PromptOnSDK.Client`, based on `Req`.

  * Bearer auth (`api_key`), `Accept: application/json`, `retry: false` (the retry policy is owned
    by Snapshot/Buffer), timeout from `config.http[:receive_timeout]` (default 5 seconds). The
    remaining keys of `config.http` (including `plug:`) are passed to Req as they are.
  * `GET /snapshot` appends `?environment=<slug>` (the `environment` setting, default
    `"production"`), sends `If-None-Match`, and does **not decode the body**
    (`decode_body: false`): the ETag is a hash of the body bytes, so the raw body is stored in the
    disk cache unchanged. Keys are per project, so this query is what selects the environment
    (2026-09-01).
  * `POST /generations` and `POST /feedback` send `{"generations": [...]}` /
    `{"feedback": [...]}` JSON.
  """

  @behaviour PromptOnSDK.Client

  alias PromptOnSDK.Config

  @impl true
  def fetch_snapshot(%{} = config, etag, opts \\ []) do
    headers = if etag, do: [{"if-none-match", etag}], else: []

    req_opts =
      [
        url: "/snapshot",
        params: [environment: Map.get(config, :environment) || Config.default_environment()],
        headers: headers,
        decode_body: false
      ]
      |> Keyword.merge(Keyword.take(opts, [:receive_timeout, :connect_options]))

    case Req.get(base(config), req_opts) do
      {:ok, %Req.Response{status: 200} = resp} ->
        {:ok,
         %{
           status: 200,
           body: resp.body,
           etag: header(resp, "etag"),
           last_modified: header(resp, "last-modified")
         }}

      {:ok, %Req.Response{status: 304}} ->
        {:ok, %{status: 304}}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:ok, %{status: status, body: body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def post_generations(config, items), do: post(config, "/generations", %{"generations" => items})

  @impl true
  def post_feedback(config, items), do: post(config, "/feedback", %{"feedback" => items})

  defp post(config, path, body) do
    case Req.post(base(config), url: path, json: body) do
      {:ok, %Req.Response{status: status, body: body, headers: headers}} ->
        {:ok, %{status: status, body: body, headers: flatten_headers(headers)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  @spec base(Config.t()) :: Req.Request.t()
  def base(config) do
    base_url = config.base_url || raise ArgumentError, "prompton_sdk base_url is not configured"

    opts =
      [
        base_url: base_url,
        retry: false,
        headers: [{"accept", "application/json"}, {"user-agent", user_agent()}]
      ]
      |> Keyword.merge(config.http)

    opts = if config.api_key, do: Keyword.put(opts, :auth, {:bearer, config.api_key}), else: opts

    Req.new(opts)
  end

  defp header(resp, name) do
    case Req.Response.get_header(resp, name) do
      [value | _] -> value
      _ -> nil
    end
  end

  defp flatten_headers(headers) when is_map(headers) do
    Map.new(headers, fn
      {k, [v | _]} -> {String.downcase(to_string(k)), v}
      {k, v} -> {String.downcase(to_string(k)), to_string(v)}
    end)
  end

  defp flatten_headers(headers) when is_list(headers) do
    Map.new(headers, fn {k, v} -> {String.downcase(to_string(k)), to_string(v)} end)
  end

  defp user_agent, do: "prompton_sdk/#{PromptOnSDK.version()}"
end
