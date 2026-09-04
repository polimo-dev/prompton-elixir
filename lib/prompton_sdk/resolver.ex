defmodule PromptOnSDK.Resolver do
  @moduledoc """
  Resolution algorithm (§5.6): snapshot + UseCase key (+ prompt name) →
  `%PromptOnSDK.Resolution{}`.

  A pure function. The SDK (`PromptOnSDK.resolve/2`) and the server's `Deployment.:resolve` action
  use **the same code**.

  ## Algorithm (snapshot v3, ADR 0007 revision 2026-09-01)

  Since a deployment revision became **a pin rather than a router**, resolution is done in two
  lookups: no rule evaluation, no conditions, no weighted selection, no context normalization.

  1. Find the UseCase by `use_case_key`. If missing, `{:error, :unknown_use_case}`.
  2. Find that UseCase's Deployment (the pin). If missing, `{:error, :unresolved}` (a use case that
     has never been deployed).
  3. Unless `kind :embedding`, look up the pin by the prompt name `opts[:prompt]` (default
     `"default"`). **A name that is not pinned gives `{:error, :unknown_prompt}`**; there is no
     silent fallback to `"default"`. An error beats sending English when the app asked for `"ko"`,
     and it is what makes a missing deployment visible.
  4. `effective_params = UseCase.default_params ⊕ Deployment.params`,
     `effective_provider_options = Model.provider_options ⊕ Deployment.provider_options`
     (`PromptOnSDK.Params.merge/2`).

  If the PromptVersion the pin points to, or the deployment's Model, is missing from the snapshot,
  the corresponding fields are left `nil` and `warnings` gets `{:missing_prompt_version, id}` /
  `{:missing_model, id}` (the server guarantees this, so it does not happen in a healthy state).
  """

  alias PromptOnSDK.{Params, Resolution, SnapshotData}

  @type error :: :unknown_use_case | :unresolved | :unknown_prompt

  @default_prompt "default"

  @doc "The name used when the request gives no prompt name."
  @spec default_prompt() :: String.t()
  def default_prompt, do: @default_prompt

  @doc """
  Resolves. `opts`:

  * `:prompt`: the prompt name to pick (default `"default"`; ignored for `kind :embedding`)
  * `:source`: `:remote | :disk | :bundle | :manual` (default `:remote`), carried into the
    Resolution as is
  * `:etag`: the snapshot ETag, carried into the Resolution as is
  """
  @spec resolve(SnapshotData.t(), String.t() | atom(), keyword()) ::
          {:ok, Resolution.t()} | {:error, error()}
  def resolve(%SnapshotData{} = snapshot, use_case_key, opts \\ []) do
    with {:ok, use_case} <- fetch_use_case(snapshot, to_key(use_case_key)),
         {:ok, deployment} <- fetch_deployment(use_case),
         {:ok, prompt_name, version_id} <- pick_prompt(use_case, deployment, opts[:prompt]) do
      {:ok, build_resolution(snapshot, use_case, deployment, prompt_name, version_id, opts)}
    end
  end

  @doc """
  The (sorted) list of prompt names this use case has pinned. `[]` when there is no deployment,
  `{:error, :unknown_use_case}` for an unknown use case.
  """
  @spec prompt_names(SnapshotData.t(), String.t() | atom()) ::
          {:ok, [String.t()]} | {:error, :unknown_use_case}
  def prompt_names(%SnapshotData{} = snapshot, use_case_key) do
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
      effective_params: Params.merge(use_case.default_params, deployment.params),
      effective_provider_options:
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
