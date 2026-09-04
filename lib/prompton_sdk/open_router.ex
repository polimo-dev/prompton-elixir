defmodule PromptOnSDK.OpenRouter do
  @moduledoc """
  OpenRouter (OpenAI-compatible chat/completions) adapter: request body assembly plus response →
  outcome extraction (§7.4, §9.5).

  The SDK does **not call the LLM** (§7.1). This module absorbs what HeyDiary's `base_body` /
  `ApiLogs.effective_cost/1` used to do.

  ## `request_body/3`

      %{"model" => r.model, "messages" => messages,
        # only (null kept) / allow_fallbacks; the key itself is omitted when empty
        "provider" => effective_provider_options,
        # all of effective_params (keys whose value is nil are omitted)
        "temperature" => …, "max_tokens" => …, …,
        # without this, cost/cost_details/is_byok are not carried in the response (§9.5)
        "usage" => %{"include" => true}}

  `overrides` are shallow-merged into the **top-level body** (`"stream" => true`,
  `"tools" => […]`, `"usage" => …`, `"provider" => …`, etc.; nested maps are replaced as a whole).
  When `provider.only` is `nil`, it is serialized as `null` (HeyDiary contract, see
  `PromptOnSDK.Params`).

  ## `outcome/1`

  Reads `choices[0].message` and `usage` from the response body (the result of `Jason.decode/1`)
  and builds the outcome map `with_generation/3` understands. The cost is `usage.cost`; **when
  `usage.is_byok`, it is `usage.cost_details.upstream_inference_cost`** (HeyDiary
  `effective_cost`). `cost_source` is `:provider` when a cost value is present, otherwise
  `:unknown` (the server fills it in from the catalog price).
  """

  alias PromptOnSDK.{Params, Resolution, StopKind}

  @doc """
  OpenRouter `POST /chat/completions` body.
  """
  @spec request_body(Resolution.t(), [map()], map()) :: map()
  def request_body(%Resolution{} = r, messages, overrides \\ %{}) when is_list(messages) do
    params =
      r.effective_params
      |> Params.stringify_keys()
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    body =
      %{"model" => r.model, "messages" => messages, "usage" => %{"include" => true}}
      |> Map.merge(params)
      |> put_provider(r.effective_provider_options)

    Map.merge(body, Params.stringify_keys(overrides))
  end

  defp put_provider(body, opts) when is_map(opts) and map_size(opts) > 0 do
    Map.put(body, "provider", Params.stringify_keys(opts))
  end

  defp put_provider(body, _), do: body

  @doc """
  Response body → outcome map.

      %{content: String.t | nil, tool_calls: list | nil, finish_reason: String.t | nil, stop_kind: atom,
        usage: %{input_tokens: int | nil, output_tokens: int | nil, raw: map | nil},
        cost_usd: number | nil, cost_source: :provider | :unknown, is_byok: boolean,
        model_used: String.t | nil, upstream_provider: String.t | nil, raw: map, result: nil}

  `result` is the slot for the app's post-processing result (`%{outcome | result: mood}`); it is
  not logged.
  """
  @spec outcome(map()) :: map()
  def outcome(body) when is_map(body) do
    choice = body |> get("choices") |> List.wrap() |> List.first() || %{}
    message = get(choice, "message") || %{}
    usage = get(body, "usage") || %{}
    finish_reason = get(choice, "finish_reason") || get(choice, "native_finish_reason")
    is_byok = get(usage, "is_byok") == true
    cost = effective_cost(usage, is_byok)

    %{
      content: get(message, "content"),
      tool_calls: get(message, "tool_calls"),
      finish_reason: finish_reason,
      stop_kind: StopKind.normalize(finish_reason),
      usage: %{
        input_tokens: get(usage, "prompt_tokens"),
        output_tokens: get(usage, "completion_tokens"),
        raw: usage
      },
      cost_usd: cost,
      cost_source: if(is_nil(cost), do: :unknown, else: :provider),
      is_byok: is_byok,
      model_used: get(body, "model"),
      upstream_provider: get(body, "provider"),
      raw: body,
      result: nil
    }
  end

  @doc """
  HeyDiary `ApiLogs.effective_cost/1`: `cost_details.upstream_inference_cost` for BYOK, otherwise
  `cost`. `nil` when absent.
  """
  @spec effective_cost(map(), boolean()) :: number() | nil
  def effective_cost(usage, is_byok) when is_map(usage) do
    upstream = get(get(usage, "cost_details") || %{}, "upstream_inference_cost")
    cost = get(usage, "cost")

    cond do
      is_byok and is_number(upstream) -> upstream
      is_number(cost) -> cost
      true -> nil
    end
  end

  def effective_cost(_, _), do: nil

  defp get(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, v} -> v
      :error -> Map.get(map, String.to_atom(key))
    end
  end

  defp get(_, _), do: nil
end
