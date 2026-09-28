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
         {:ok, tool_fields} <- provider_tool_fields(resolution.tools),
         {:ok, params} <- reject_tool_param_conflicts(params, tool_fields),
         {:ok, body} <- render_body(resolution, variables) do
      body = body |> Map.merge(params) |> Map.merge(tool_fields) |> put_provider(options)

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

    if is_list(messages) and messages != [] do
      with {:ok, rendered} <-
             Template.render_messages(messages, variables, engine: resolution.engine),
           true <- rendered != [] and Enum.all?(rendered, &valid_message?/1) do
        {:ok, %{"model" => resolution.model, "messages" => rendered}}
      else
        false -> {:error, :invalid_messages}
        error -> error
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

  defp provider_tool_fields(nil), do: {:ok, %{}}

  defp provider_tool_fields(tools) do
    tools = Decisions.normalize(tools)

    cond do
      not is_map(tools) ->
        {:error, :invalid_tools}

      not Decisions.json?(tools) ->
        {:error, :invalid_tools}

      not is_list(tools["definitions"]) ->
        {:error, :invalid_tools}

      Map.keys(tools) -- ~w(definitions tool_choice parallel_tool_calls) != [] ->
        {:error, :invalid_tools}

      true ->
        with :ok <- validate_tool_definitions(tools["definitions"]),
             :ok <- validate_tool_policy(tools) do
          fields =
            %{"tools" => Enum.map(tools["definitions"], &strip_tool_metadata/1)}
            |> maybe_put("tool_choice", tools["tool_choice"])
            |> maybe_put("parallel_tool_calls", tools["parallel_tool_calls"])

          {:ok, fields}
        end
    end
  end

  defp validate_tool_definitions(definitions) do
    if Enum.all?(definitions, &valid_tool_definition?/1),
      do: :ok,
      else: {:error, :invalid_tools}
  end

  defp valid_tool_definition?(%{"type" => "function", "function" => function} = tool)
       when is_map(function) do
    Map.keys(tool) -- ~w(type function output_schema output_examples) == [] and
      valid_function_tool?(function) and
      valid_output_schema?(tool["output_schema"]) and
      valid_output_examples?(tool["output_examples"])
  end

  defp valid_tool_definition?(_), do: false

  defp valid_function_tool?(function) do
    is_binary(function["name"]) and String.trim(function["name"]) != "" and
      (is_nil(function["description"]) or is_binary(function["description"])) and
      (is_nil(function["parameters"]) or is_map(function["parameters"]))
  end

  defp valid_output_schema?(nil), do: true
  defp valid_output_schema?(schema), do: is_map(schema)

  defp valid_output_examples?(nil), do: true
  defp valid_output_examples?(examples), do: is_list(examples)

  defp validate_tool_policy(tools) do
    cond do
      not is_nil(tools["tool_choice"]) and
        tools["tool_choice"] not in ["auto", "none", "required"] and
          not is_map(tools["tool_choice"]) ->
        {:error, :invalid_tools}

      not is_nil(tools["parallel_tool_calls"]) and not is_boolean(tools["parallel_tool_calls"]) ->
        {:error, :invalid_tools}

      true ->
        :ok
    end
  end

  defp strip_tool_metadata(tool) do
    tool
    |> Decisions.normalize()
    |> Map.drop(["output_schema", "output_examples"])
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp reject_tool_param_conflicts(params, tool_fields) when map_size(tool_fields) == 0,
    do: {:ok, params}

  defp reject_tool_param_conflicts(params, tool_fields) do
    conflicts =
      tool_fields
      |> Map.keys()
      |> Enum.filter(&(Map.has_key?(params, &1) and params[&1] != tool_fields[&1]))
      |> Enum.sort()

    if conflicts == [] do
      {:ok, Map.drop(params, Map.keys(tool_fields))}
    else
      {:error, {:tool_param_conflict, conflicts}}
    end
  end

  defp valid_message?(%{"role" => role} = message),
    do:
      role in ["system", "user", "assistant", "developer", "tool"] and
        Decisions.json?(message)

  defp valid_message?(_), do: false
  defp put_provider(body, options) when map_size(options) == 0, do: body
  defp put_provider(body, options), do: Map.put(body, "provider", options)
end
