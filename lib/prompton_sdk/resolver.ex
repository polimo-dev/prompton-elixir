defmodule PromptOnSDK.Resolver do
  @moduledoc false

  alias PromptOnSDK.{Params, Resolution, UseCaseDocument}

  @type error :: :unknown_use_case | :unresolved | :unknown_prompt

  @default_prompt "default"

  @doc false
  @spec default_prompt() :: String.t()
  def default_prompt, do: @default_prompt

  @doc false
  @spec resolve(UseCaseDocument.t(), String.t() | atom(), keyword()) ::
          {:ok, Resolution.t()} | {:error, error()}
  def resolve(%UseCaseDocument{} = snapshot, use_case_key, opts \\ []) do
    with {:ok, use_case} <- fetch_use_case(snapshot, to_key(use_case_key)),
         {:ok, deployment} <- fetch_deployment(use_case),
         {:ok, prompt_name, version_id} <- pick_prompt(use_case, deployment, opts[:prompt]) do
      {:ok, build_resolution(snapshot, use_case, deployment, prompt_name, version_id, opts)}
    end
  end

  @doc false
  @spec prompt_names(UseCaseDocument.t(), String.t() | atom()) ::
          {:ok, [String.t()]} | {:error, :unknown_use_case}
  def prompt_names(%UseCaseDocument{} = snapshot, use_case_key) do
    with {:ok, use_case} <- fetch_use_case(snapshot, to_key(use_case_key)) do
      case Map.get(use_case, :deployment) do
        %{prompt_pins: pins} when is_map(pins) -> {:ok, pins |> Map.keys() |> Enum.sort()}
        _ -> {:ok, []}
      end
    end
  end

  # ---------------------------------------------------------------------------

  defp fetch_use_case(snapshot, key) do
    case Map.fetch(snapshot.use_cases, key) do
      {:ok, use_case} -> {:ok, use_case}
      :error -> {:error, :unknown_use_case}
    end
  end

  defp fetch_deployment(use_case) do
    case Map.get(use_case, :deployment) do
      %{} = deployment -> {:ok, deployment}
      _ -> {:error, :unresolved}
    end
  end

  # `kind :embedding` has no prompt: a given name is ignored and only the model is resolved.
  defp pick_prompt(%{kind: :embedding}, _deployment, _requested), do: {:ok, nil, nil}

  defp pick_prompt(_use_case, deployment, requested) do
    name = to_key(requested) || @default_prompt

    case Map.fetch(deployment.prompt_pins || %{}, name) do
      {:ok, version_id} -> {:ok, name, version_id}
      :error -> {:error, :unknown_prompt}
    end
  end

  defp build_resolution(snapshot, use_case, deployment, prompt_name, version_id, opts) do
    {prompt_version, warnings} =
      lookup(snapshot.prompt_versions, version_id, :missing_prompt_version, [])

    {model, warnings} = lookup(snapshot.models, deployment.model_id, :missing_model, warnings)

    %Resolution{
      use_case_key: use_case.key,
      kind: use_case.kind,
      prompt: prompt_name,
      deployment_id: deployment.id,
      deployment_revision: deployment.revision,
      prompt_version_id: prompt_version && prompt_version.id,
      prompt_version_number: prompt_version && prompt_version.number,
      engine: prompt_version && prompt_version.engine,
      model_id: model && model.id,
      model: model && model.model_id,
      provider: model && model.provider,
      params: Params.merge(use_case.default_params, deployment.params),
      provider_options:
        Params.merge(model && model.provider_options, deployment.provider_options),
      messages: template_messages(use_case.kind, prompt_version),
      text_template: template_text(use_case.kind, prompt_version),
      input_schema: use_case.input_schema,
      source: Keyword.get(opts, :source, :remote),
      etag: Keyword.get(opts, :etag),
      payload_policy: use_case.payload_policy,
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
