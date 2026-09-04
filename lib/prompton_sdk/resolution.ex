defmodule PromptOnSDK.Resolution do
  @moduledoc """
  The result of `PromptOnSDK.Resolver.resolve/3`: "what to use for this call" (§7.4).

  The app calls the LLM directly with this struct (`model`, `effective_params`,
  `effective_provider_options`, `messages`) and records the resolution evidence in the log
  (`PromptOnSDK.log/1`, `with_generation/3`): `deployment_id` / `deployment_revision` / `prompt` /
  `prompt_version_id`.

  | Field | Description |
  |---|---|
  | `use_case_key` | The resolved UseCase key |
  | `kind` | `:chat` / `:text` / `:embedding` |
  | `prompt` | The chosen prompt name (default `"default"`). `nil` for `:embedding` |
  | `deployment_id`, `deployment_revision` | The Deployment revision that produced this resolution |
  | `prompt_version_id`, `prompt_version_number`, `engine` | The pinned prompt version (`nil` for `:embedding`). `engine` is `:liquid`/`:raw` |
  | `model_id` | Catalog `Model.id` (UUID) |
  | `model` | Provider model string (`"anthropic/claude-sonnet-4"`), used in the request body as is |
  | `provider` | `:openrouter`, etc. |
  | `effective_params` | `UseCase.default_params ⊕ Deployment.params` (string keys, shallow merge) |
  | `effective_provider_options` | `Model.provider_options ⊕ Deployment.provider_options` (`nil` values preserved) |
  | `messages` | `kind :chat`: `[%{role: "system", content: "..."}]`, the **raw template** (before rendering) |
  | `text_template` | `kind :text`: a single string template. `nil` for the other kinds |
  | `input_schema` | The UseCase input variable schema |
  | `source` | Snapshot source `:remote` / `:disk` / `:bundle` / `:manual` |
  | `etag` | Snapshot ETag |
  | `payload_policy` | Raw-text storage policy (snapshot value, applied by the log batcher) |
  | `warnings` | Warnings raised during resolution (e.g. `{:missing_model, id}`) |

  Since resolution no longer takes a context (ADR 0007 revision 2026-09-01), `context` is not a
  Resolution field. To record it in the log, pass it as `meta.context` to `with_generation/3`
  (free-form pass-through).
  """

  @type message :: %{
          required(:role) => String.t(),
          required(:content) => String.t(),
          optional(:name) => String.t() | nil
        }

  @type source :: :remote | :disk | :bundle | :manual

  @type t :: %__MODULE__{
          use_case_key: String.t(),
          kind: :chat | :text | :embedding,
          prompt: String.t() | nil,
          deployment_id: String.t() | nil,
          deployment_revision: non_neg_integer() | nil,
          prompt_version_id: String.t() | nil,
          prompt_version_number: non_neg_integer() | nil,
          engine: :liquid | :raw | nil,
          model_id: String.t() | nil,
          model: String.t() | nil,
          provider: atom() | nil,
          effective_params: map(),
          effective_provider_options: map(),
          messages: [message()] | nil,
          text_template: String.t() | nil,
          input_schema: [map()],
          source: source(),
          etag: String.t() | nil,
          payload_policy: map() | nil,
          warnings: [term()]
        }

  defstruct use_case_key: nil,
            kind: nil,
            prompt: nil,
            deployment_id: nil,
            deployment_revision: nil,
            prompt_version_id: nil,
            prompt_version_number: nil,
            engine: nil,
            model_id: nil,
            model: nil,
            provider: nil,
            effective_params: %{},
            effective_provider_options: %{},
            messages: nil,
            text_template: nil,
            input_schema: [],
            source: :remote,
            etag: nil,
            payload_policy: nil,
            warnings: []
end
