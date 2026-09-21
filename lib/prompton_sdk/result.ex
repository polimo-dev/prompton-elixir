defmodule PromptOnSDK.Result do
  @moduledoc """
  Normalized provider result for `PromptOnSDK.Prompt.track/3`.
  """

  @type t :: %__MODULE__{
          content: String.t() | nil,
          finish_reason: String.t() | nil,
          stop_kind: atom() | nil,
          usage: map(),
          cost_usd: number() | nil,
          cost_source: atom() | nil,
          is_byok: boolean(),
          tool_calls: term(),
          model_used: String.t() | nil,
          upstream_provider: String.t() | nil,
          raw: map() | nil,
          result: term()
        }

  defstruct content: nil,
            finish_reason: nil,
            stop_kind: nil,
            usage: %{},
            cost_usd: nil,
            cost_source: nil,
            is_byok: false,
            tool_calls: nil,
            model_used: nil,
            upstream_provider: nil,
            raw: nil,
            result: nil

  alias PromptOnSDK.{Decisions, StopKind}

  @atom_keys ~w(
    choices completion_tokens content cost cost_details cost_source finish_reason input_tokens
    is_byok message model model_used native_finish_reason output_tokens provider prompt_tokens
    raw raw_usage result stop_kind text tool_calls upstream_inference_cost upstream_provider
    usage usage_raw
  )
  @atom_key_lookup Map.new(@atom_keys, &{&1, String.to_atom(&1)})

  @doc "Normalize an OpenAI-compatible response."
  @spec from_openai(map()) :: t()
  def from_openai(body) when is_map(body) do
    choice = body |> get("choices") |> List.wrap() |> List.first() || %{}
    message = get(choice, "message") || %{}
    usage = get(body, "usage") || %{}
    finish_reason = get(choice, "finish_reason") || get(choice, "native_finish_reason")
    is_byok = get(usage, "is_byok") == true
    cost = effective_cost(usage, is_byok)

    %__MODULE__{
      content: get(message, "content") || get(choice, "text"),
      finish_reason: finish_reason,
      stop_kind: StopKind.normalize(finish_reason),
      tool_calls: get(message, "tool_calls"),
      usage: %{
        input_tokens: get(usage, "prompt_tokens") || get(usage, "input_tokens"),
        output_tokens: get(usage, "completion_tokens") || get(usage, "output_tokens"),
        raw: usage
      },
      cost_usd: cost,
      cost_source: if(is_nil(cost), do: :unknown, else: :provider),
      is_byok: is_byok,
      model_used: get(body, "model"),
      upstream_provider: get(body, "provider"),
      raw: body
    }
  end

  @doc """
  Normalize a Decisions response, preserving every typed answer and probability in `result`,
  `content` (JSON), and `raw`. The tagged result can be returned directly from `track/3`.
  """
  @spec from_decisions(map()) :: {:ok, t()} | {:error, :invalid_decisions_response}
  def from_decisions(body) when is_map(body) and not is_struct(body) do
    normalized = Decisions.normalize(body)
    answers = normalized["answers"]
    usage = normalized["usage"]

    if valid_decisions_response?(normalized, answers, usage) do
      is_byok = usage["is_byok"] == true
      cost = effective_cost(usage, is_byok)

      {:ok,
       %__MODULE__{
         content: Jason.encode!(answers),
         result: answers,
         finish_reason: "stop",
         stop_kind: :stop,
         tool_calls: [],
         usage: %{
           input_tokens: usage["input_tokens"],
           output_tokens: usage["output_tokens"],
           raw: usage
         },
         cost_usd: cost,
         cost_source: if(is_nil(cost), do: :unknown, else: :provider),
         is_byok: is_byok,
         model_used: normalized["model"],
         upstream_provider: normalized["provider"],
         raw: body
       }}
    else
      {:error, :invalid_decisions_response}
    end
  end

  def from_decisions(_), do: {:error, :invalid_decisions_response}

  defp valid_decisions_response?(body, answers, usage) do
    Decisions.json?(body) and is_map(answers) and map_size(answers) > 0 and
      Enum.all?(answers, fn {_name, answer} -> valid_decision_answer?(answer) end) and
      valid_decision_usage?(usage) and
      is_binary(body["model"]) and body["model"] != ""
  end

  defp valid_decision_usage?(usage) when is_map(usage),
    do: Enum.all?(["input_tokens", "output_tokens"], &(is_integer(usage[&1]) and usage[&1] >= 0))

  defp valid_decision_usage?(_), do: false

  defp valid_decision_answer?(answer) when is_map(answer) do
    value_valid =
      case answer["type"] do
        "choice" -> is_binary(answer["choice"])
        type when type in ["score", "noul"] -> is_number(answer[type])
        _ -> false
      end

    probabilities = answer["probabilities"]

    value_valid and (is_nil(answer["confidence"]) or is_number(answer["confidence"])) and
      (is_nil(probabilities) or
         (is_map(probabilities) and
            Enum.all?(probabilities, fn {_key, value} -> is_number(value) end)))
  end

  defp valid_decision_answer?(_), do: false

  @doc "Normalize an Anthropic Messages response."
  @spec from_anthropic(map()) :: t()
  def from_anthropic(body) when is_map(body) do
    usage = get(body, "usage") || %{}
    finish_reason = get(body, "stop_reason")

    %__MODULE__{
      content: anthropic_content(get(body, "content")),
      finish_reason: finish_reason,
      stop_kind: StopKind.normalize(finish_reason),
      usage: %{
        input_tokens: get(usage, "input_tokens"),
        output_tokens: get(usage, "output_tokens"),
        raw: usage
      },
      cost_source: :unknown,
      model_used: get(body, "model"),
      raw: body
    }
  end

  @doc "Normalize values already extracted by application/provider-specific code."
  @spec from_generic(map()) :: t()
  def from_generic(map) when is_map(map) do
    finish_reason = get(map, :finish_reason)
    cost = get(map, :cost_usd)

    %__MODULE__{
      content: get(map, :content),
      tool_calls: get(map, :tool_calls),
      finish_reason: finish_reason,
      stop_kind: generic_stop_kind(map, finish_reason),
      usage: generic_usage(map),
      cost_usd: cost,
      cost_source: generic_cost_source(map, cost),
      is_byok: get(map, :is_byok) == true,
      model_used: get(map, :model_used),
      upstream_provider: get(map, :upstream_provider),
      raw: get(map, :raw),
      result: get(map, :result)
    }
  end

  @doc false
  @spec to_log_fields(t()) :: map()
  def to_log_fields(%__MODULE__{} = result),
    do: result |> Map.from_struct() |> Map.delete(:__struct__)

  defp anthropic_content(blocks) when is_list(blocks) do
    blocks
    |> Enum.filter(&(get(&1, "type") == "text"))
    |> Enum.map_join("", &(get(&1, "text") || ""))
  end

  defp anthropic_content(content) when is_binary(content), do: content
  defp anthropic_content(_), do: nil

  defp generic_stop_kind(map, finish_reason) do
    case get(map, :stop_kind) do
      nil -> StopKind.normalize(finish_reason)
      kind -> StopKind.normalize(kind)
    end
  end

  defp generic_usage(map) do
    %{
      input_tokens: get(map, :input_tokens),
      output_tokens: get(map, :output_tokens),
      raw: get(map, :usage_raw) || get(map, :raw_usage)
    }
  end

  defp generic_cost_source(map, cost) do
    case get(map, :cost_source) do
      nil -> if(is_nil(cost), do: :unknown, else: :provider)
      source when is_atom(source) -> source
      "provider" -> :provider
      "catalog" -> :catalog
      "unknown" -> :unknown
      _ -> :unknown
    end
  end

  defp effective_cost(usage, is_byok) when is_map(usage) do
    upstream = get(get(usage, "cost_details") || %{}, "upstream_inference_cost")
    cost = get(usage, "cost")

    cond do
      is_byok and is_number(upstream) -> upstream
      is_number(cost) -> cost
      true -> nil
    end
  end

  defp effective_cost(_, _), do: nil

  defp get(map, key) when is_map(map) and is_binary(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, @atom_key_lookup[key])
    end
  end

  defp get(map, key) when is_map(map) and is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp get(_map, _key), do: nil
end
