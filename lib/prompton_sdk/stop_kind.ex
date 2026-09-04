defmodule PromptOnSDK.StopKind do
  @moduledoc """
  Normalizes each provider's raw `finish_reason` into a `stop_kind` (§5.7).

  SDK adapters (`PromptOnSDK.OpenRouter.outcome/1`, etc.) and the server ingest share the same
  table.

  | Raw (`finish_reason`) | `stop_kind` | Source |
  |---|---|---|
  | `stop`, `end_turn`, `stop_sequence` | `:stop` | OpenAI/OpenRouter, Anthropic |
  | `length`, `max_tokens` | `:length` | OpenAI/OpenRouter, Anthropic |
  | `tool_calls`, `tool_use` | `:tool_call` | OpenAI/OpenRouter, Anthropic |
  | `content_filter` | `:content_filter` | OpenAI/OpenRouter |
  | anything else / `nil` | `:other` | |

  Comparison is case-insensitive and ignores surrounding whitespace (`"STOP"` → `:stop`).
  **Normalization is idempotent**: already-normalized values (`stop`, `length`, `tool_call`,
  `content_filter`, `other`; string or atom) pass through unchanged (`"tool_call"` →
  `:tool_call`). `Generation.build/8` re-normalizes the `stop_kind` of an adapter-built outcome,
  and the server ingest normalizes the client's `stop_kind` with the same rules, so without this
  property `tool_call` would turn into `:other`.
  `truncated?/1` is true only when `stop_kind == :length`; **`tool_calls` is not a truncation**
  (the truncation rate, the evaluator, and alerts share this definition).
  """

  @type t :: :stop | :length | :tool_call | :content_filter | :other

  # The normalized value itself (`tool_call`) is in the table too, making normalize/1 idempotent
  # (the other normalized values are the same as their raw forms).
  @stop ~w(stop end_turn stop_sequence)
  @length ~w(length max_tokens)
  @tool_call ~w(tool_call tool_calls tool_use)
  @content_filter ~w(content_filter)

  @doc """
  Normalizes a raw `finish_reason` (string, atom, or `nil`) into `t()`.

  ## Examples

      iex> PromptOnSDK.StopKind.normalize("end_turn")
      :stop

      iex> PromptOnSDK.StopKind.normalize("max_tokens")
      :length

      iex> PromptOnSDK.StopKind.normalize(nil)
      :other

      iex> PromptOnSDK.StopKind.normalize(:tool_call)
      :tool_call
  """
  @spec normalize(String.t() | atom() | nil) :: t()
  def normalize(nil), do: :other

  def normalize(reason) when is_atom(reason), do: reason |> Atom.to_string() |> normalize()

  def normalize(reason) when is_binary(reason) do
    case reason |> String.trim() |> String.downcase() do
      r when r in @stop -> :stop
      r when r in @length -> :length
      r when r in @tool_call -> :tool_call
      r when r in @content_filter -> :content_filter
      _ -> :other
    end
  end

  def normalize(_), do: :other

  @doc """
  Whether the output was truncated. Accepts a `stop_kind` (atom) or a raw `finish_reason`.

      iex> PromptOnSDK.StopKind.truncated?(:length)
      true

      iex> PromptOnSDK.StopKind.truncated?("tool_calls")
      false
  """
  @spec truncated?(t() | String.t() | nil) :: boolean()
  def truncated?(:length), do: true
  def truncated?(kind) when kind in [:stop, :tool_call, :content_filter, :other], do: false
  def truncated?(reason), do: normalize(reason) == :length
end
