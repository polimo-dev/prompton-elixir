defmodule PromptOnSDK.Params do
  @moduledoc """
  Shallow-merge helper for parameter maps.

  Used to compute `effective_params = UseCase.default_params ⊕ Deployment.params` and
  `effective_provider_options = Model.provider_options ⊕ Deployment.provider_options` (§5.5).
  The server and the SDK share the same rules.

  Rules:

  * **Shallow merge**: nested maps are not merged recursively; the override's value replaces them
    as a whole.
  * **Keys are normalized to strings**: snapshots use string keys while app code may use atom
    keys, so `%{temperature: 0.7}` and `%{"temperature" => 0.5}` are treated as the same key.
  * **Explicit `nil` is preserved**: HeyDiary must send OpenRouter `provider.only: null`, so when
    an override puts `nil`, that key stays with a `nil` value (it is not deleted). The adapter
    serializes it as `null`.
  * A `nil` argument is treated as an empty map.
  """

  @type params :: %{optional(String.t()) => term()}

  @doc """
  Shallow-merges `override` on top of `base`. `override` wins.

  ## Examples

      iex> PromptOnSDK.Params.merge(%{"temperature" => 0.5, "top_p" => 1}, %{temperature: 0.7})
      %{"temperature" => 0.7, "top_p" => 1}

      iex> PromptOnSDK.Params.merge(%{"only" => ["Anthropic"]}, %{"only" => nil})
      %{"only" => nil}

      iex> PromptOnSDK.Params.merge(nil, nil)
      %{}
  """
  @spec merge(map() | nil, map() | nil) :: params()
  def merge(base, override) do
    Map.merge(stringify_keys(base), stringify_keys(override))
  end

  @doc """
  Normalizes the map's top-level keys to strings. Returns an empty map for a non-map (including
  `nil`).
  """
  @spec stringify_keys(map() | nil) :: params()
  def stringify_keys(map) when is_map(map) and not is_struct(map) do
    Map.new(map, fn
      {k, v} when is_binary(k) -> {k, v}
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {to_string(k), v}
    end)
  end

  def stringify_keys(_), do: %{}
end
