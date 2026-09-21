defmodule PromptOnSDK.Prompt do
  @moduledoc """
  A deployed PromptOn prompt ready for an application call.

  Fetch one with `PromptOnSDK.prompt/2`, render it with `messages/2` or `text/2`, then wrap the
  provider call with `track/3`.
  """

  alias PromptOnSDK.{Generation, ProviderRequest, Resolution, Template}

  @selection_key {__MODULE__, :selected_prompts}

  @type message :: %{
          required(:role) => String.t(),
          required(:content) => String.t(),
          optional(:name) => String.t() | nil
        }

  @type t :: %__MODULE__{
          key: String.t(),
          kind: :chat | :decision | :text | :embedding,
          model: String.t() | nil,
          model_id: String.t() | nil,
          provider: atom() | nil,
          api: :chat_completions | :decisions | nil,
          request_path: String.t() | nil,
          decision: map() | nil,
          params: map(),
          provider_options: map(),
          deployment: %{id: String.t() | nil, revision: non_neg_integer() | nil},
          template: String.t() | nil,
          template_names: [String.t()],
          prompt_version: %{id: String.t() | nil, number: non_neg_integer() | nil} | nil,
          engine: :liquid | :raw | nil,
          messages: [message()] | nil,
          text_template: String.t() | nil,
          source: atom(),
          input_schema: [map()],
          payload_policy: map() | nil,
          warnings: [term()],
          etag: String.t() | nil
        }

  defstruct key: nil,
            kind: nil,
            model: nil,
            model_id: nil,
            provider: nil,
            api: nil,
            request_path: nil,
            decision: nil,
            params: %{},
            provider_options: %{},
            deployment: %{id: nil, revision: nil},
            template: nil,
            template_names: [],
            prompt_version: nil,
            engine: nil,
            messages: nil,
            text_template: nil,
            source: :remote,
            input_schema: [],
            payload_policy: nil,
            warnings: [],
            etag: nil

  @doc false
  @spec from_resolution(Resolution.t(), [String.t()]) :: t()
  def from_resolution(%Resolution{} = r, template_names \\ []) do
    %__MODULE__{
      key: r.prompt_key,
      kind: r.kind,
      model: r.model,
      model_id: r.model_id,
      provider: r.provider,
      api: r.api,
      request_path: r.request_path,
      decision: r.decision,
      params: r.params,
      provider_options: r.provider_options,
      deployment: %{id: r.deployment_id, revision: r.deployment_revision},
      template: r.template,
      template_names: template_names,
      prompt_version:
        r.prompt_version_id &&
          %{id: r.prompt_version_id, number: r.prompt_version_number},
      engine: r.engine,
      messages: r.messages,
      text_template: r.text_template,
      source: r.source,
      input_schema: r.input_schema,
      payload_policy: r.payload_policy,
      warnings: r.warnings,
      etag: r.etag
    }
  end

  @doc "Prepare a provider POST request without making a provider call. Supports template selection and request overrides."
  @spec request(t(), map() | nil, keyword()) :: {:ok, ProviderRequest.t()} | {:error, term()}
  def request(%__MODULE__{} = prompt, variables, opts \\ []) do
    case select_prompt(prompt, opts) do
      {:ok, selected} ->
        result =
          ProviderRequest.build(
            to_resolution(selected),
            variables,
            Keyword.delete(opts, :template)
          )

        remember_prompt_selection(selected, opts, result)
        result

      error ->
        clear_prompt_selection(prompt)
        error
    end
  end

  @doc "Render a chat prompt into provider messages."
  @spec messages(t(), map() | nil, keyword()) ::
          {:ok, [map()]} | {:error, :wrong_kind | :no_template | Template.render_error()}
  def messages(prompt, variables, opts \\ [])

  def messages(%__MODULE__{} = prompt, variables, opts) do
    case select_prompt(prompt, opts) do
      {:ok, prompt} ->
        result =
          case prompt do
            %{kind: :chat} ->
              Template.render_messages(prompt.messages || [], variables,
                engine: prompt.engine || :liquid
              )

            _other ->
              {:error, :wrong_kind}
          end

        remember_prompt_selection(prompt, opts, result)
        result

      error ->
        clear_prompt_selection(prompt)
        error
    end
  end

  @doc "Render a text prompt into a single provider input string."
  @spec text(t(), map() | nil, keyword()) ::
          {:ok, String.t()} | {:error, :wrong_kind | :no_template | Template.render_error()}
  def text(prompt, variables, opts \\ [])

  def text(%__MODULE__{} = prompt, variables, opts) do
    case select_prompt(prompt, opts) do
      {:ok, prompt} ->
        result =
          case prompt do
            %{kind: :text, text_template: text} when is_binary(text) ->
              Template.render(text, variables, engine: prompt.engine || :liquid)

            _other ->
              {:error, :wrong_kind}
          end

        remember_prompt_selection(prompt, opts, result)
        result

      error ->
        clear_prompt_selection(prompt)
        error
    end
  end

  @doc "Wrap a provider call and enqueue one monitoring log."
  @spec track(t(), keyword() | map(), (-> term())) :: term()
  def track(%__MODULE__{} = prompt, meta \\ [], fun) when is_function(fun, 0) do
    template =
      case prompt_opt(meta) do
        nil ->
          pop_prompt_selection(prompt)

        explicit_prompt ->
          clear_prompt_selection(prompt)
          explicit_prompt
      end

    case select_prompt(prompt, template: template) do
      {:ok, prompt} ->
        Generation.with_generation(to_resolution(prompt), drop_prompt(meta), fun)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  @spec to_resolution(t()) :: Resolution.t()
  def to_resolution(%__MODULE__{} = prompt) do
    %Resolution{
      prompt_key: prompt.key,
      kind: prompt.kind,
      template: prompt.template,
      deployment_id: prompt.deployment.id,
      deployment_revision: prompt.deployment.revision,
      prompt_version_id: prompt.prompt_version && prompt.prompt_version.id,
      prompt_version_number: prompt.prompt_version && prompt.prompt_version.number,
      engine: prompt.engine,
      model_id: prompt.model_id,
      model: prompt.model,
      provider: prompt.provider,
      api: prompt.api,
      request_path: prompt.request_path,
      decision: prompt.decision,
      params: prompt.params,
      provider_options: prompt.provider_options,
      messages: prompt.messages,
      text_template: prompt.text_template,
      input_schema: prompt.input_schema,
      source: prompt.source,
      etag: prompt.etag,
      payload_policy: prompt.payload_policy,
      warnings: prompt.warnings
    }
  end

  defp select_prompt(prompt, opts) do
    case prompt_opt(opts) do
      nil ->
        {:ok, prompt}

      template when template == prompt.template ->
        {:ok, prompt}

      template ->
        PromptOnSDK.prompt(prompt.key, template: template)
    end
  end

  defp remember_prompt_selection(prompt, opts, result) do
    case {prompt_opt(opts), result} do
      {nil, _} ->
        clear_prompt_selection(prompt)

      {_prompt, {:ok, _rendered}} ->
        put_prompt_selection(prompt)

      {_prompt, _error} ->
        clear_prompt_selection(prompt)
    end
  end

  defp put_prompt_selection(%__MODULE__{} = prompt) do
    selections =
      Process.get(@selection_key, %{})
      |> Map.put(prompt.key, prompt.template)

    Process.put(@selection_key, selections)
    :ok
  end

  defp clear_prompt_selection(%__MODULE__{} = prompt) do
    selections =
      Process.get(@selection_key, %{})
      |> Map.delete(prompt.key)

    if map_size(selections) == 0 do
      Process.delete(@selection_key)
    else
      Process.put(@selection_key, selections)
    end

    :ok
  end

  defp pop_prompt_selection(%__MODULE__{} = prompt) do
    selections = Process.get(@selection_key, %{})
    {prompt, selections} = Map.pop(selections, prompt.key)

    if map_size(selections) == 0 do
      Process.delete(@selection_key)
    else
      Process.put(@selection_key, selections)
    end

    prompt
  end

  defp prompt_opt(opts) when is_list(opts), do: Keyword.get(opts, :template)
  defp prompt_opt(opts) when is_map(opts), do: opts[:template] || opts["template"]
  defp prompt_opt(_opts), do: nil

  defp drop_prompt(opts) when is_list(opts), do: Keyword.drop(opts, [:template, "template"])
  defp drop_prompt(opts) when is_map(opts), do: Map.drop(opts, [:template, "template"])
  defp drop_prompt(opts), do: opts
end
