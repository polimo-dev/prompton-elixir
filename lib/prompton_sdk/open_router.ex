defmodule PromptOnSDK.OpenRouter do
  @moduledoc """
  OpenRouter (OpenAI-compatible chat/completions) adapter: request body assembly (§7.4, §9.5).

  The SDK does **not call the LLM** (§7.1). This module only assembles the body you post; the
  HTTP call stays in your code.

  ## `request_body/3`

      %{"model" => r.model, "messages" => messages,
        # only (null kept) / allow_fallbacks; the key itself is omitted when empty
        "provider" => provider_options,
        # all of params (keys whose value is nil are omitted)
        "temperature" => …, "max_tokens" => …, …,
        # without this, cost/cost_details/is_byok are not carried in the response (§9.5)
        "usage" => %{"include" => true}}

  `overrides` are shallow-merged into the **top-level body** (`"stream" => true`,
  `"tools" => […]`, `"usage" => …`, `"provider" => …`, etc.; nested maps are replaced as a whole).
  When `provider.only` is `nil`, it is serialized as `null` (see `PromptOnSDK.Params`).

  Use `PromptOnSDK.Result.from_openai/1` to normalize the response body before returning from
  `PromptOnSDK.track/3`.
  """

  alias PromptOnSDK.{Params, Resolution, UseCase}

  @doc """
  OpenRouter `POST /chat/completions` body.
  """
  @spec request_body(UseCase.t(), [map()], map()) :: map()
  def request_body(%UseCase{} = use_case, messages, overrides \\ %{}) when is_list(messages),
    do: request_body_from_resolution(UseCase.to_resolution(use_case), messages, overrides)

  defp request_body_from_resolution(%Resolution{} = r, messages, overrides)
       when is_list(messages) do
    params =
      r.params
      |> Params.stringify_keys()
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    body =
      %{"model" => r.model, "messages" => messages, "usage" => %{"include" => true}}
      |> Map.merge(params)
      |> put_provider(r.provider_options)

    Map.merge(body, Params.stringify_keys(overrides))
  end

  defp put_provider(body, opts) when is_map(opts) and map_size(opts) > 0 do
    Map.put(body, "provider", Params.stringify_keys(opts))
  end

  defp put_provider(body, _), do: body
end
