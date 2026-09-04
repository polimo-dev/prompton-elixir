defmodule PromptOnSDK.Generic do
  @moduledoc """
  Generic outcome builder. Normalizes the values the app extracted from a non-OpenRouter provider
  (Groq Whisper, OpenAI embeddings, etc.) into the outcome shape `with_generation/3` understands
  (§7.4).

      PromptOnSDK.Generic.outcome(%{input_tokens: 120, output_tokens: 0, content: text,
                                    finish_reason: "stop", cost_usd: nil, raw: resp})

  Accepted keys (atom or string): `content`, `tool_calls`, `finish_reason`, `stop_kind`
  (normalized from `finish_reason` when absent), `input_tokens`, `output_tokens`, `cost_usd`,
  `cost_source` (when absent: `:provider` if there is a cost, otherwise `:unknown`), `model_used`,
  `upstream_provider`, `is_byok`, `raw`, `result` (the app's post-processing result; not logged).
  """

  alias PromptOnSDK.StopKind

  @doc "Normalizes into an outcome map."
  @spec outcome(map()) :: map()
  def outcome(map) when is_map(map) do
    finish_reason = get(map, :finish_reason)
    cost = get(map, :cost_usd)

    stop_kind =
      case get(map, :stop_kind) do
        nil -> StopKind.normalize(finish_reason)
        kind -> StopKind.normalize(kind)
      end

    cost_source =
      case get(map, :cost_source) do
        nil -> if(is_nil(cost), do: :unknown, else: :provider)
        source when is_atom(source) -> source
        source when is_binary(source) -> String.to_existing_atom(source)
      end

    %{
      content: get(map, :content),
      tool_calls: get(map, :tool_calls),
      finish_reason: finish_reason,
      stop_kind: stop_kind,
      usage: %{
        input_tokens: get(map, :input_tokens),
        output_tokens: get(map, :output_tokens),
        raw: get(map, :usage_raw) || get(map, :raw_usage)
      },
      cost_usd: cost,
      cost_source: cost_source,
      is_byok: get(map, :is_byok) == true,
      model_used: get(map, :model_used),
      upstream_provider: get(map, :upstream_provider),
      raw: get(map, :raw),
      result: get(map, :result)
    }
  end

  defp get(map, key) when is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, v} -> v
      :error -> Map.get(map, Atom.to_string(key))
    end
  end
end
