defmodule PromptOnSDK.Generation do
  @moduledoc false

  alias PromptOnSDK.{Params, Resolution, Result, StopKind, Telemetry, UUIDv7}

  @error_kinds ~w(http_4xx http_5xx rate_limited timeout transport parse app)

  @doc false
  @spec with_generation(Resolution.t(), map() | keyword(), (-> term())) :: term()
  def with_generation(%Resolution{} = r, meta, fun) when is_function(fun, 0) do
    meta = normalize_meta(meta)
    id = meta[:id] || UUIDv7.generate()
    started_at = DateTime.utc_now()
    t0 = System.monotonic_time()

    Telemetry.execute(Telemetry.log_start(), %{system_time: System.system_time()}, %{
      id: id,
      use_case: r.use_case_key,
      prompt: r.prompt,
      deployment_id: r.deployment_id,
      model: r.model,
      kind: r.kind,
      trace_id: meta[:trace_id],
      sequence: meta[:sequence]
    })

    try do
      result = fun.()
      {status, provider_result, error} = classify(result)
      gen = build(r, meta, id, started_at, t0, status, provider_result, error)
      PromptOnSDK.log(gen, policy: r.payload_policy)

      Telemetry.execute(
        Telemetry.log_stop(),
        %{
          duration: System.monotonic_time() - t0,
          latency_ms: gen["latency_ms"],
          input_tokens: get_in(gen, ["usage", "input_tokens"]),
          output_tokens: get_in(gen, ["usage", "output_tokens"]),
          cost_usd: get_in(gen, ["usage", "cost_usd"])
        },
        %{
          id: id,
          use_case: r.use_case_key,
          prompt: r.prompt,
          deployment_id: r.deployment_id,
          model: r.model,
          status: status,
          stop_kind: gen["stop_kind"],
          error_kind: get_in(gen, ["error", "kind"])
        }
      )

      result
    catch
      kind, reason ->
        stacktrace = __STACKTRACE__
        message = format_exception(kind, reason)
        error = %{kind: :app, message: message}
        gen = build(r, meta, id, started_at, t0, :error, nil, error)
        PromptOnSDK.log(gen, policy: r.payload_policy)

        Telemetry.execute(
          Telemetry.log_exception(),
          %{duration: System.monotonic_time() - t0, latency_ms: gen["latency_ms"]},
          %{
            id: id,
            use_case: r.use_case_key,
            prompt: r.prompt,
            deployment_id: r.deployment_id,
            model: r.model,
            kind: kind,
            reason: reason,
            stacktrace: stacktrace
          }
        )

        :erlang.raise(kind, reason, stacktrace)
    end
  end

  # ---------------------------------------------------------------------------

  defp classify({:ok, provider_result}), do: {:ok, provider_result, nil}
  defp classify({:error, error}), do: {:error, nil, error}
  defp classify({:error, error, provider_result}), do: {:error, provider_result, error}
  defp classify(_other), do: {:ok, nil, nil}

  @doc false
  @spec build(
          Resolution.t(),
          map(),
          String.t(),
          DateTime.t(),
          integer(),
          :ok | :error,
          term(),
          term()
        ) :: map()
  def build(r, meta, id, started_at, t0, status, provider_result, error) do
    latency_ms = System.convert_time_unit(System.monotonic_time() - t0, :native, :millisecond)
    provider_result = normalize_result(provider_result)
    usage = provider_result[:usage] || %{}

    metadata =
      meta[:metadata]
      |> Params.stringify_keys()
      |> maybe_put("is_byok", provider_result[:is_byok])

    %{
      "id" => id,
      "use_case" => r.use_case_key,
      # Use-case evidence: the deployment revision and the chosen prompt. Keys whose value is
      # nil are dropped entirely below.
      "deployment_id" => r.deployment_id,
      "deployment_revision" => r.deployment_revision,
      "prompt" => r.prompt,
      "prompt_version_id" => r.prompt_version_id,
      "source" => to_str(r.source),
      "context" => Params.stringify_keys(meta[:context] || %{}),
      "kind" => to_str(r.kind),
      "model" => r.model,
      "model_used" => provider_result[:model_used],
      "provider" => to_str(r.provider),
      "upstream_provider" => provider_result[:upstream_provider],
      "params" => Params.merge(r.params, meta[:params]),
      "input" => build_input(meta),
      "output" => build_output(provider_result),
      "status" => to_str(status),
      "finish_reason" => to_str(provider_result[:finish_reason]),
      "stop_kind" => stop_kind(provider_result),
      "error" => build_error(error),
      "usage" => %{
        "input_tokens" => usage[:input_tokens],
        "output_tokens" => usage[:output_tokens],
        "cost_usd" => provider_result[:cost_usd],
        "cost_source" => to_str(provider_result[:cost_source] || :unknown),
        "raw" => usage[:raw]
      },
      "latency_ms" => latency_ms,
      "started_at" => DateTime.to_iso8601(started_at),
      "trace_id" => meta[:trace_id],
      "sequence" => meta[:sequence],
      "end_user_ref" => meta[:end_user_ref] && to_string(meta[:end_user_ref]),
      "metadata" => metadata,
      "sdk" => %{"name" => "prompton_sdk", "version" => PromptOnSDK.version()}
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp build_input(meta) do
    input =
      %{}
      |> maybe_put("variables", meta[:variables] && Params.stringify_keys(meta[:variables]))
      |> maybe_put("messages", meta[:input_messages])

    if map_size(input) == 0, do: nil, else: input
  end

  defp build_output(nil), do: nil

  defp build_output(provider_result) do
    output =
      %{}
      |> maybe_put("content", provider_result[:content])
      |> maybe_put("tool_calls", provider_result[:tool_calls])

    if map_size(output) == 0, do: nil, else: output
  end

  defp build_error(nil), do: nil

  defp build_error(error) when is_map(error) do
    kind = error |> get(:kind) |> to_str() || "app"
    kind = if kind in @error_kinds, do: kind, else: "app"
    status = get(error, :status)
    message = get(error, :message)

    %{
      "kind" => kind,
      "status" => if(is_integer(status), do: status),
      "message" => if(is_nil(message), do: nil, else: to_message(message))
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp build_error(error), do: %{"kind" => "app", "message" => to_message(error)}

  defp stop_kind(nil), do: nil

  defp stop_kind(provider_result) do
    case provider_result[:stop_kind] do
      nil ->
        case provider_result[:finish_reason] do
          nil -> nil
          reason -> reason |> StopKind.normalize() |> to_str()
        end

      kind ->
        kind |> StopKind.normalize() |> to_str()
    end
  end

  defp normalize_result(nil), do: nil
  defp normalize_result(content) when is_binary(content), do: %{content: content}

  defp normalize_result(%Result{} = result),
    do: result |> Result.to_log_fields() |> normalize_result()

  defp normalize_result(provider_result) when is_map(provider_result) do
    provider_result =
      atomize(provider_result, [
        :content,
        :tool_calls,
        :finish_reason,
        :stop_kind,
        :usage,
        :cost_usd,
        :cost_source,
        :is_byok,
        :model_used,
        :upstream_provider,
        :input_tokens,
        :output_tokens
      ])

    usage =
      case provider_result[:usage] do
        %{} = u ->
          atomize(u, [:input_tokens, :output_tokens, :raw])

        _ ->
          %{
            input_tokens: provider_result[:input_tokens],
            output_tokens: provider_result[:output_tokens],
            raw: nil
          }
      end

    Map.put(provider_result, :usage, usage)
  end

  defp normalize_result(_), do: nil

  defp normalize_meta(meta) when is_list(meta), do: normalize_meta(Map.new(meta))

  defp normalize_meta(meta) when is_map(meta) do
    atomize(meta, [
      :id,
      :end_user_ref,
      :trace_id,
      :sequence,
      :input_messages,
      :variables,
      :metadata,
      :context,
      :params
    ])
  end

  defp normalize_meta(_), do: %{}

  defp atomize(map, keys) do
    Enum.reduce(keys, %{}, fn key, acc ->
      case get(map, key) do
        nil -> acc
        v -> Map.put(acc, key, v)
      end
    end)
  end

  defp get(map, key) when is_map(map) and is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, v} -> v
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp get(_, _), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp to_str(nil), do: nil
  defp to_str(v) when is_atom(v), do: Atom.to_string(v)
  defp to_str(v) when is_binary(v), do: v
  defp to_str(v), do: to_string(v)

  defp to_message(msg) when is_binary(msg), do: msg
  defp to_message(msg), do: inspect(msg, limit: 50, printable_limit: 2_048)

  defp format_exception(:error, %{__exception__: true} = e),
    do: Exception.format_banner(:error, e)

  defp format_exception(kind, reason), do: Exception.format_banner(kind, reason)
end
