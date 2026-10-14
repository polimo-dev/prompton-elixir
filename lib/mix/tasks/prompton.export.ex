defmodule Mix.Tasks.Prompton.Export do
  @shortdoc "Exports PromptOn prompt details into a schema v1 bundle file"

  @moduledoc """
  Fetches the lightweight `GET /prompts` index, fetches each `GET /prompts/:key` detail, assembles
  a schema v1 bundle file, and writes a `<out>.meta.json` sidecar. This is the last-resort fallback
  of §7.3. CI runs it on every build and commits the result to the repo:
  "even if PromptOn disappears, the app keeps running on the Release from the last export".

      mix prompton.export [--out priv/prompton/prompts.production.json] [--base-url URL] [--api-key KEY]

  Configuration precedence: flags, then the `PTN_BASE_URL` / `PTN_API_KEY` environment variables,
  then `config :prompton_sdk`.
  On failure (network, non-200, decode failure) the task exits abnormally **without touching the
  existing file** (CI keeps the committed file and warns).
  The sidecar carries `etag`, `last_modified`, `environment`, and `exported_at` (= `fetched_at`).
  """

  use Mix.Task

  alias PromptOnSDK.{Config, PromptDocument}
  alias PromptOnSDK.Snapshot.Store

  @default_out "priv/prompton/prompts.production.json"

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
    with {:ok, %{status: 200} = list_resp} <- fetch_list(config),
         {:ok, list} <- decode_body(list_resp.body),
         {:ok, bundle} <- assemble_bundle(config, list),
         {:ok, body} <- Jason.encode(bundle),
         etag = local_etag(body),
         now = DateTime.utc_now(),
         meta = %{
           "etag" => etag,
           "last_modified" => nil,
           "environment" => bundle["environment"],
           "project" => bundle["project"],
           "fetched_at" => DateTime.to_iso8601(now),
           "exported_at" => DateTime.to_iso8601(now),
           "source" => "assembled-local"
         },
         :ok <- Store.write_file(out, body, meta) do
      {:ok, %{environment: bundle["environment"], etag: etag, last_modified: nil}}
    else
      {:ok, %{status: status} = resp} -> {:error, {:http, status, Map.get(resp, :body)}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_list(config) do
    config.client.fetch_prompts(config, nil, receive_timeout: 15_000)
  rescue
    e -> {:error, {:client_exception, e}}
  end

  defp fetch_detail(config, key) do
    config.client.fetch_prompt(config, key, nil, receive_timeout: 15_000)
  rescue
    e -> {:error, {:client_exception, e}}
  end

  defp decode_body(body) when is_binary(body), do: Jason.decode(body)
  defp decode_body(body) when is_map(body), do: {:ok, body}
  defp decode_body(body), do: {:error, {:invalid_body, body}}

  defp assemble_bundle(config, %{"schema_version" => 1, "prompts" => prompts} = list)
       when is_list(prompts) do
    with :ok <- validate_list_scope(config, list),
         {:ok, items} <- normalize_list_items(prompts),
         {:ok, empty} <- empty_bundle(list) do
      fetch_details(config, empty, items)
    end
  end

  defp assemble_bundle(_config, _list),
    do:
      {:error,
       {:invalid_prompt_list, "GET /prompts must return schema_version 1 and prompts array"}}

  defp validate_list_scope(config, list) do
    with project when is_binary(project) and project != "" <- Map.get(list, "project"),
         environment when is_binary(environment) and environment != "" <-
           Map.get(list, "environment"),
         :ok <-
           require_equal(
             environment,
             config.env_slug,
             {:environment_mismatch, :index, environment, config.env_slug}
           ) do
      :ok
    else
      nil -> {:error, {:invalid_prompt_list, :missing_scope}}
      "" -> {:error, {:invalid_prompt_list, :missing_scope}}
      {:error, reason} -> {:error, reason}
      _ -> {:error, {:invalid_prompt_list, :invalid_scope}}
    end
  end

  defp empty_bundle(list) do
    {:ok,
     %{
       "schema_version" => 1,
       "project" => Map.fetch!(list, "project"),
       "environment" => Map.fetch!(list, "environment"),
       "prompts" => %{},
       "deployments" => %{},
       "prompt_versions" => %{},
       "models" => %{}
     }}
  end

  defp normalize_list_items(prompts) do
    Enum.reduce_while(prompts, {:ok, %{}}, fn item, {:ok, acc} ->
      key = is_map(item) && item["key"]
      kind = is_map(item) && item["kind"]

      cond do
        not is_binary(key) or key == "" ->
          {:halt, {:error, {:invalid_prompt_list, {:invalid_key, item}}}}

        Map.has_key?(acc, key) ->
          {:halt, {:error, {:invalid_prompt_list, {:duplicate_key, key}}}}

        true ->
          {:cont, {:ok, Map.put(acc, key, kind)}}
      end
    end)
    |> case do
      {:ok, map} -> {:ok, Enum.sort_by(map, fn {key, _kind} -> key end)}
      other -> other
    end
  end

  defp fetch_details(config, bundle, items) do
    Enum.reduce_while(items, {:ok, bundle}, fn {key, kind}, {:ok, acc} ->
      case fetch_one_detail(config, key, kind, acc) do
        {:ok, acc} -> {:cont, {:ok, acc}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp fetch_one_detail(config, key, list_kind, acc) do
    with {:ok, %{status: 200} = resp} <- fetch_detail(config, key),
         body = to_bytes(resp.body),
         {:ok, raw} <- decode_body(body),
         {:ok, data, _warnings} <- PromptDocument.decode(raw),
         :ok <- validate_detail(config, acc, key, list_kind, data) do
      detail_to_bundle(acc, key, raw)
    else
      {:ok, %{status: status} = resp} ->
        {:error, {:detail_http, key, status, Map.get(resp, :body)}}

      {:error, reason} ->
        {:error, {:detail, key, reason}}
    end
  end

  defp validate_detail(config, bundle, key, list_kind, data) do
    with :ok <-
           require_equal(
             data.project,
             bundle["project"],
             {:project_mismatch, key, data.project, bundle["project"]}
           ),
         :ok <-
           require_equal(
             data.environment,
             bundle["environment"],
             {:environment_mismatch, key, data.environment, bundle["environment"]}
           ),
         :ok <-
           require_equal(
             data.environment,
             config.env_slug,
             {:environment_mismatch, key, data.environment, config.env_slug}
           ),
         [^key] <- Map.keys(data.prompts),
         prompt = data.prompts[key],
         :ok <-
           require_equal(
             Atom.to_string(prompt.kind),
             list_kind,
             {:kind_mismatch, key, prompt.kind, list_kind}
           ) do
      :ok
    else
      keys when is_list(keys) -> {:error, {:key_mismatch, key, keys}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp detail_to_bundle(bundle, key, raw) do
    with {:ok, prompt} <- fetch_detail_object(raw, "prompt"),
         {:ok, deployment} <- fetch_detail_object(raw, "deployment"),
         {:ok, prompt_version} <- fetch_detail_object(raw, "prompt_version"),
         {:ok, model} <- fetch_detail_object(raw, "model") do
      prompt = Map.delete(prompt, "key")
      prompt_version_key = "#{key}@#{prompt_version["number"]}"
      model_key = "#{model["provider"]}:#{model["model"]}"

      with {:ok, bundle} <- merge_resource(bundle, "prompts", %{key => prompt}),
           {:ok, bundle} <- merge_resource(bundle, "deployments", %{key => deployment}),
           {:ok, bundle} <-
             merge_resource(bundle, "prompt_versions", %{prompt_version_key => prompt_version}) do
        merge_resource(bundle, "models", %{model_key => model})
      end
    end
  end

  defp fetch_detail_object(raw, key) do
    case Map.get(raw, key) do
      value when is_map(value) -> {:ok, value}
      _ -> {:error, {:invalid_detail_shape, key}}
    end
  end

  defp merge_resource(bundle, name, entries) do
    Enum.reduce_while(entries, {:ok, bundle}, fn {key, value}, {:ok, acc} ->
      encoded = Jason.decode!(Jason.encode!(value))
      existing = acc[name][key]

      cond do
        is_nil(existing) -> {:cont, {:ok, put_in(acc, [name, key], encoded)}}
        existing == encoded -> {:cont, {:ok, acc}}
        true -> {:halt, {:error, {:resource_collision, name, key}}}
      end
    end)
  end

  defp require_equal(value, value, _reason), do: :ok
  defp require_equal(_left, _right, reason), do: {:error, reason}

  defp local_etag(body) do
    "sha256-" <> Base.encode16(:crypto.hash(:sha256, body), case: :lower)
  end

  defp to_bytes(body) when is_binary(body), do: body
  defp to_bytes(body) when is_map(body), do: Jason.encode!(body)
  defp to_bytes(body), do: body
end
