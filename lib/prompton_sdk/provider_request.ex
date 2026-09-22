defmodule PromptOnSDK.ProviderRequest do
  @moduledoc "A prepared provider request. This module never sends HTTP."

  alias PromptOnSDK.{Decisions, Resolution, Template}

  @type t :: %{
          api: :chat_completions | :decisions,
          method: :post,
          path: String.t(),
          body: map()
        }

  @paths %{
    {:openrouter, :chat_completions} => ["/api/v1/chat/completions"],
    {:openrouter, :decisions} => ["/api/v1/systemone", "/api/alpha/decisions"],
    {:openai, :chat_completions} => ["/v1/chat/completions"],
    {:groq, :chat_completions} => ["/openai/v1/chat/completions"]
  }
  @protected ~w(model messages state questions provider usage api request_path method path body)
  @decision_params ~w(session_id trace user)

  @doc false
  @spec build(Resolution.t(), map() | nil, keyword()) :: {:ok, t()} | {:error, term()}
  def build(%Resolution{} = resolution, variables, opts \\ []) do
    with {:ok, resolution} <- apply_options(resolution, opts),
         :ok <- validate_metadata(resolution),
         :ok <- validate_variables(variables),
         {:ok, params} <- request_params(resolution),
         {:ok, options} <- provider_options(resolution),
         {:ok, body} <- render_body(resolution, variables) do
      body = body |> Map.merge(params) |> put_provider(options)

      body =
        if resolution.provider == :openrouter and resolution.api == :chat_completions,
          do: Map.put(body, "usage", %{"include" => true}),
          else: body

      {:ok, %{api: resolution.api, method: :post, path: resolution.request_path, body: body}}
    end
  end

  defp apply_options(resolution, opts) do
    allowed = [:params, :provider_options, :session_id, :trace, :user]

    cond do
      not Keyword.keyword?(opts) ->
        {:error, :invalid_request_options}

      Keyword.keys(opts) -- allowed != [] ->
        {:error, :invalid_request_options}

      resolution.api != :decisions and
          Enum.any?([:session_id, :trace, :user], &Keyword.has_key?(opts, &1)) ->
        {:error, :decision_options_require_decisions_api}

      true ->
        with {:ok, params} <- merge_override(resolution.params, opts[:params], :invalid_params),
             {:ok, provider} <-
               merge_override(
                 resolution.provider_options,
                 opts[:provider_options],
                 :invalid_provider_options
               ) do
          metadata =
            opts
            |> Keyword.take([:session_id, :trace, :user])
            |> Map.new()
            |> Decisions.normalize()

          {:ok, %{resolution | params: Map.merge(params, metadata), provider_options: provider}}
        end
    end
  end

  defp merge_override(base, override, error) do
    base = Decisions.normalize(base)
    override = Decisions.normalize(if(is_nil(override), do: %{}, else: override))

    if is_map(base) and not is_struct(base) and is_map(override) and not is_struct(override),
      do: {:ok, Map.merge(base, override)},
      else: {:error, error}
  end

  defp validate_metadata(%{api: nil}), do: {:error, :missing_request_metadata}
  defp validate_metadata(%{request_path: nil}), do: {:error, :missing_request_metadata}

  defp validate_metadata(resolution) do
    cond do
      resolution.kind not in [:chat, :decision] ->
        {:error, :unsupported_prompt_kind}

      {resolution.kind, resolution.api} not in [chat: :chat_completions, decision: :decisions] ->
        {:error, :request_kind_mismatch}

      not Map.has_key?(@paths, {resolution.provider, resolution.api}) ->
        {:error, :unsupported_provider_api}

      resolution.request_path not in @paths[{resolution.provider, resolution.api}] ->
        {:error, :invalid_request_path}

      not is_binary(resolution.model) or String.trim(resolution.model) == "" ->
        {:error, :missing_model}

      resolution.engine not in [:liquid, :raw] ->
        {:error, :invalid_template_engine}

      true ->
        :ok
    end
  end

  defp validate_variables(nil), do: :ok
  defp validate_variables(vars) when is_map(vars) and not is_struct(vars), do: :ok
  defp validate_variables(_), do: {:error, :invalid_variables}

  defp request_params(resolution) do
    params = Decisions.normalize(resolution.params)

    if is_map(params) and not is_struct(params) and Decisions.json?(params) do
      protected = Map.keys(params) |> Enum.filter(&(&1 in @protected)) |> Enum.sort()

      unsupported =
        if resolution.api == :decisions, do: Map.keys(params) -- @decision_params, else: []

      cond do
        protected != [] -> {:error, {:protected_params, protected}}
        unsupported != [] -> {:error, {:unsupported_decision_params, Enum.sort(unsupported)}}
        resolution.api == :decisions -> validate_decision_params(params)
        true -> {:ok, Map.reject(params, fn {_key, value} -> is_nil(value) end)}
      end
    else
      {:error, :invalid_params}
    end
  end

  defp validate_decision_params(params) do
    invalid =
      Enum.find(params, fn
        {key, value} when key in ["session_id", "user"] ->
          not is_binary(value) or String.length(value) > 256

        {"trace", value} ->
          not is_map(value)
      end)

    case invalid do
      nil -> {:ok, params}
      {key, _} -> {:error, {:invalid_decision_param, key}}
    end
  end

  defp provider_options(resolution) do
    options = Decisions.normalize(resolution.provider_options)

    cond do
      not is_map(options) or is_struct(options) or not Decisions.json?(options) ->
        {:error, :invalid_provider_options}

      resolution.provider != :openrouter and map_size(options) > 0 ->
        {:error, :unsupported_provider_options}

      true ->
        {:ok, options}
    end
  end

  defp render_body(%{api: :chat_completions} = resolution, variables) do
    messages = Decisions.normalize(resolution.messages)

    if is_list(messages) and messages != [] and Enum.all?(messages, &valid_message?/1) do
      with {:ok, rendered} <-
             Template.render_messages(messages, variables, engine: resolution.engine) do
        {:ok, %{"model" => resolution.model, "messages" => rendered}}
      end
    else
      {:error, :invalid_messages}
    end
  end

  defp render_body(%{api: :decisions} = resolution, variables) do
    with {:ok, decision} <- Decisions.render(resolution.decision, variables, resolution.engine) do
      {:ok, Map.put(decision, "model", resolution.model)}
    end
  end

  defp valid_message?(%{"role" => role, "content" => content} = message),
    do:
      role in ["system", "user", "assistant", "developer", "tool"] and is_binary(content) and
        Decisions.json?(message)

  defp valid_message?(_), do: false
  defp put_provider(body, options) when map_size(options) == 0, do: body
  defp put_provider(body, options), do: Map.put(body, "provider", options)
end
