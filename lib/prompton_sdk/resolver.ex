defmodule PromptOnSDK.Resolver do
  @moduledoc false

  alias PromptOnSDK.{Params, PromptDocument, Resolution}

  @type error :: :unknown_prompt | :unresolved | :unknown_template

  @default_template "default"

  @doc false
  @spec default_template() :: String.t()
  def default_template, do: @default_template

  @doc false
  @spec resolve(PromptDocument.t(), String.t() | atom(), keyword()) ::
          {:ok, Resolution.t()} | {:error, error()}
  def resolve(%PromptDocument{} = snapshot, prompt_key, opts \\ []) do
    with {:ok, prompt} <- fetch_prompt(snapshot, to_key(prompt_key)),
         {:ok, deployment} <- fetch_deployment(prompt),
         {:ok, prompt_name, version_id} <- pick_prompt(prompt, deployment, opts[:template]) do
      {:ok, build_resolution(snapshot, prompt, deployment, prompt_name, version_id, opts)}
    end
  end

  @doc false
  @spec template_names(PromptDocument.t(), String.t() | atom()) ::
          {:ok, [String.t()]} | {:error, :unknown_prompt}
  def template_names(%PromptDocument{} = snapshot, prompt_key) do
    with {:ok, prompt} <- fetch_prompt(snapshot, to_key(prompt_key)) do
      case Map.get(prompt, :deployment) do
        %{template_pins: pins} when is_map(pins) -> {:ok, pins |> Map.keys() |> Enum.sort()}
        _ -> {:ok, []}
      end
    end
  end

  # ---------------------------------------------------------------------------

  defp fetch_prompt(snapshot, key) do
    case Map.fetch(snapshot.prompts, key) do
      {:ok, prompt} -> {:ok, prompt}
      :error -> {:error, :unknown_prompt}
    end
  end

  defp fetch_deployment(prompt) do
    case Map.get(prompt, :deployment) do
      %{} = deployment -> {:ok, deployment}
      _ -> {:error, :unresolved}
    end
  end

  # `kind :embedding` has no template: a given name is ignored and only the model is resolved.
  defp pick_prompt(%{kind: :embedding}, _deployment, _requested), do: {:ok, nil, nil}

  defp pick_prompt(_prompt, deployment, requested) do
    name = to_key(requested) || @default_template

    case Map.fetch(deployment.template_pins || %{}, name) do
      {:ok, version_id} -> {:ok, name, version_id}
      :error -> {:error, :unknown_template}
    end
  end

  defp build_resolution(snapshot, prompt, deployment, prompt_name, version_id, opts) do
    {prompt_version, warnings} =
      lookup(snapshot.prompt_versions, version_id, :missing_prompt_version, [])

    {model, warnings} = lookup(snapshot.models, deployment.model_id, :missing_model, warnings)

    %Resolution{
      prompt_key: prompt.key,
      kind: prompt.kind,
      template: prompt_name,
      deployment_id: deployment.id,
      deployment_revision: deployment.revision,
      prompt_version_id: prompt_version && prompt_version.id,
      prompt_version_number: prompt_version && prompt_version.number,
      engine: prompt_version && prompt_version.engine,
      model_id: model && model.id,
      model: model && model.model_id,
      provider: model && model.provider,
      params: Params.merge(prompt.default_params, deployment.params),
      provider_options:
        Params.merge(model && model.provider_options, deployment.provider_options),
      messages: template_messages(prompt.kind, prompt_version),
      text_template: template_text(prompt.kind, prompt_version),
      input_schema: prompt.input_schema,
      source: Keyword.get(opts, :source, :remote),
      etag: Keyword.get(opts, :etag),
      payload_policy: prompt.payload_policy,
      warnings: warnings
    }
  end

  defp template_messages(:chat, %{messages: messages}) when is_list(messages), do: messages
  defp template_messages(_, _), do: nil

  defp template_text(:text, %{text_template: text}) when is_binary(text), do: text
  defp template_text(_, _), do: nil

  defp lookup(_map, nil, _tag, warnings), do: {nil, warnings}

  defp lookup(map, id, tag, warnings) do
    case Map.fetch(map, id) do
      {:ok, entry} -> {entry, warnings}
      :error -> {nil, warnings ++ [{tag, id}]}
    end
  end

  defp to_key(key) when is_binary(key), do: key
  defp to_key(key) when is_atom(key) and not is_nil(key), do: Atom.to_string(key)
  defp to_key(_key), do: nil
end
