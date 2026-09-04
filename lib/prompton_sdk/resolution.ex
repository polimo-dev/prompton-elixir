defmodule PromptOnSDK.Resolution do
  @moduledoc false

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
          params: map(),
          provider_options: map(),
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
            params: %{},
            provider_options: %{},
            messages: nil,
            text_template: nil,
            input_schema: [],
            source: :remote,
            etag: nil,
            payload_policy: nil,
            warnings: []
end
