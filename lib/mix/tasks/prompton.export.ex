defmodule Mix.Tasks.Prompton.Export do
  @shortdoc "Downloads the PromptOn snapshot into a bundle file (GET /snapshot)"

  @moduledoc """
  Fetches `GET /snapshot` and saves it as a bundle file (plus a `<out>.meta.json` sidecar); this is
  the last-resort fallback of §7.3. CI runs it on every build and commits the result to the repo:
  "even if PromptOn disappears, the app keeps running on the Release from the last export".

      mix prompton.export [--out priv/prompton/snapshot.json] [--base-url URL] [--api-key KEY]

  Configuration precedence: flags, then the `PTN_BASE_URL` / `PTN_API_KEY` environment variables,
  then `config :prompton_sdk`.
  On failure (network, non-200, decode failure) the task exits abnormally **without touching the
  existing file** (CI keeps the committed file and warns).
  The sidecar carries `etag`, `last_modified`, `environment`, and `exported_at` (= `fetched_at`).
  """

  use Mix.Task

  alias PromptOnSDK.{Config, SnapshotData}
  alias PromptOnSDK.Snapshot.Store

  @default_out "priv/prompton/snapshot.json"

  @impl Mix.Task
  def run(args) do
    {opts, _rest, _invalid} =
      OptionParser.parse(args, strict: [out: :string, base_url: :string, api_key: :string])

    Mix.Task.run("app.config", [])
    {:ok, _} = Application.ensure_all_started(:req)

    out = opts[:out] || @default_out

    overrides =
      [
        base_url: opts[:base_url] || System.get_env("PTN_BASE_URL"),
        api_key: opts[:api_key] || System.get_env("PTN_API_KEY")
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    config = Config.load(overrides)

    if is_nil(config.base_url) or is_nil(config.api_key) do
      Mix.raise(
        "prompton.export: base_url and api_key are required (flags, PTN_* env, or config :prompton_sdk)"
      )
    end

    case export(config, out) do
      {:ok, entry} ->
        Mix.shell().info(
          "prompton.export: wrote #{out} (environment=#{entry.environment} etag=#{entry.etag} last_modified=#{entry.last_modified})"
        )

      {:error, reason} ->
        Mix.raise("prompton.export: failed, existing file left untouched: #{inspect(reason)}")
    end
  end

  @doc false
  @spec export(Config.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def export(config, out) do
    with {:ok, %{status: 200} = resp} <- fetch(config),
         body = to_bytes(resp.body),
         {:ok, data, _warnings} <- SnapshotData.decode_json(body),
         now = DateTime.utc_now(),
         meta = %{
           "etag" => resp.etag,
           "last_modified" => resp.last_modified,
           "environment" => data.environment,
           "fetched_at" => DateTime.to_iso8601(now),
           "exported_at" => DateTime.to_iso8601(now)
         },
         :ok <- Store.write_file(out, body, meta) do
      {:ok, %{environment: data.environment, etag: resp.etag, last_modified: resp.last_modified}}
    else
      {:ok, %{status: status} = resp} -> {:error, {:http, status, Map.get(resp, :body)}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch(config) do
    config.client.fetch_snapshot(config, nil, receive_timeout: 15_000)
  rescue
    e -> {:error, {:client_exception, e}}
  end

  defp to_bytes(body) when is_binary(body), do: body
  defp to_bytes(body) when is_map(body), do: Jason.encode!(body)
end
