defmodule PromptOnSDK.UseCase do
  @moduledoc """
  A deployed PromptOn use case ready for an application call.

  Fetch one with `PromptOnSDK.use_case/2`, render it with `messages/2` or `text/2`, then wrap the
  provider call with `track/3`.
  """

  alias PromptOnSDK.{Generation, Resolution, Template}

  @selection_key {__MODULE__, :selected_prompts}

  @type message :: %{
          required(:role) => String.t(),
          required(:content) => String.t(),
          optional(:name) => String.t() | nil
        }

  @type t :: %__MODULE__{
          key: String.t(),
          kind: :chat | :text | :embedding,
          model: String.t() | nil,
          model_id: String.t() | nil,
          provider: atom() | nil,
          params: map(),
          provider_options: map(),
          deployment: %{id: String.t() | nil, revision: non_neg_integer() | nil},
          prompt: String.t() | nil,
          prompt_names: [String.t()],
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
            params: %{},
            provider_options: %{},
            deployment: %{id: nil, revision: nil},
            prompt: nil,
            prompt_names: [],
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
  def from_resolution(%Resolution{} = r, prompt_names \\ []) do
    %__MODULE__{
      key: r.use_case_key,
      kind: r.kind,
      model: r.model,
      model_id: r.model_id,
      provider: r.provider,
      params: r.params,
      provider_options: r.provider_options,
      deployment: %{id: r.deployment_id, revision: r.deployment_revision},
      prompt: r.prompt,
      prompt_names: prompt_names,
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

  @doc "Render a chat use case into provider messages."
  @spec messages(t(), map() | nil, keyword()) ::
          {:ok, [map()]} | {:error, :wrong_kind | :no_template | Template.render_error()}
  def messages(use_case, variables, opts \\ [])

  def messages(%__MODULE__{} = use_case, variables, opts) do
    case select_prompt(use_case, opts) do
      {:ok, use_case} ->
        result =
          case use_case do
            %{kind: :chat} ->
              Template.render_messages(use_case.messages || [], variables,
                engine: use_case.engine || :liquid
              )

            _other ->
              {:error, :wrong_kind}
          end

        remember_prompt_selection(use_case, opts, result)
        result

      error ->
        clear_prompt_selection(use_case)
        error
    end
  end

  @doc "Render a text use case into a single provider input string."
  @spec text(t(), map() | nil, keyword()) ::
          {:ok, String.t()} | {:error, :wrong_kind | :no_template | Template.render_error()}
  def text(use_case, variables, opts \\ [])

  def text(%__MODULE__{} = use_case, variables, opts) do
    case select_prompt(use_case, opts) do
      {:ok, use_case} ->
        result =
          case use_case do
            %{kind: :text, text_template: text} when is_binary(text) ->
              Template.render(text, variables, engine: use_case.engine || :liquid)

            _other ->
              {:error, :wrong_kind}
          end

        remember_prompt_selection(use_case, opts, result)
        result

      error ->
        clear_prompt_selection(use_case)
        error
    end
  end

  @doc "Wrap a provider call and enqueue one monitoring log."
  @spec track(t(), keyword() | map(), (-> term())) :: term()
  def track(%__MODULE__{} = use_case, meta \\ [], fun) when is_function(fun, 0) do
    prompt =
      case prompt_opt(meta) do
        nil ->
          pop_prompt_selection(use_case)

        explicit_prompt ->
          clear_prompt_selection(use_case)
          explicit_prompt
      end

    case select_prompt(use_case, prompt: prompt) do
      {:ok, use_case} ->
        Generation.with_generation(to_resolution(use_case), drop_prompt(meta), fun)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  @spec to_resolution(t()) :: Resolution.t()
  def to_resolution(%__MODULE__{} = use_case) do
    %Resolution{
      use_case_key: use_case.key,
      kind: use_case.kind,
      prompt: use_case.prompt,
      deployment_id: use_case.deployment.id,
      deployment_revision: use_case.deployment.revision,
      prompt_version_id: use_case.prompt_version && use_case.prompt_version.id,
      prompt_version_number: use_case.prompt_version && use_case.prompt_version.number,
      engine: use_case.engine,
      model_id: use_case.model_id,
      model: use_case.model,
      provider: use_case.provider,
      params: use_case.params,
      provider_options: use_case.provider_options,
      messages: use_case.messages,
      text_template: use_case.text_template,
      input_schema: use_case.input_schema,
      source: use_case.source,
      etag: use_case.etag,
      payload_policy: use_case.payload_policy,
      warnings: use_case.warnings
    }
  end

  defp select_prompt(use_case, opts) do
    case prompt_opt(opts) do
      nil ->
        {:ok, use_case}

      prompt when prompt == use_case.prompt ->
        {:ok, use_case}

      prompt ->
        PromptOnSDK.use_case(use_case.key, prompt: prompt)
    end
  end

  defp remember_prompt_selection(use_case, opts, result) do
    case {prompt_opt(opts), result} do
      {nil, _} ->
        clear_prompt_selection(use_case)

      {_prompt, {:ok, _rendered}} ->
        put_prompt_selection(use_case)

      {_prompt, _error} ->
        clear_prompt_selection(use_case)
    end
  end

  defp put_prompt_selection(%__MODULE__{} = use_case) do
    selections =
      Process.get(@selection_key, %{})
      |> Map.put(use_case.key, use_case.prompt)

    Process.put(@selection_key, selections)
    :ok
  end

  defp clear_prompt_selection(%__MODULE__{} = use_case) do
    selections =
      Process.get(@selection_key, %{})
      |> Map.delete(use_case.key)

    if map_size(selections) == 0 do
      Process.delete(@selection_key)
    else
      Process.put(@selection_key, selections)
    end

    :ok
  end

  defp pop_prompt_selection(%__MODULE__{} = use_case) do
    selections = Process.get(@selection_key, %{})
    {prompt, selections} = Map.pop(selections, use_case.key)

    if map_size(selections) == 0 do
      Process.delete(@selection_key)
    else
      Process.put(@selection_key, selections)
    end

    prompt
  end

  defp prompt_opt(opts) when is_list(opts), do: Keyword.get(opts, :prompt)
  defp prompt_opt(opts) when is_map(opts), do: opts[:prompt] || opts["prompt"]
  defp prompt_opt(_opts), do: nil

  defp drop_prompt(opts) when is_list(opts), do: Keyword.drop(opts, [:prompt, "prompt"])
  defp drop_prompt(opts) when is_map(opts), do: Map.drop(opts, [:prompt, "prompt"])
  defp drop_prompt(opts), do: opts
end
