defmodule PromptOnSDK.Fixtures do
  @moduledoc """
  Reference snapshot for tests (§6.2 format **v3**, HeyDiary mapping). A string-keyed map, the same
  shape as a `Jason.decode/1` result.

  A deployment is a pin, not a router: one model per use case plus one version pin per prompt name.

  * `diary_generation`: chat. Two pins (`default` = English, `ko` = Korean). Model sonnet4,
    temperature 0.5
  * `chat_response`: chat. One pin (`default`). Model gpt5-mini
  * `voice_transcription`: kind text, raw engine, one pin (`default`). Model whisper. Payload
    policy `:hash`
  * `diary_embedding`: kind embedding, no pins. Model embed. Payload policy `:none`
  * `transcript_revision`: no deployment -> the `{:error, :unresolved}` case
  """

  @ids %{
    uc_diary: "cc554326-c4b9-4582-a675-22104d6d29e0",
    uc_chat: "9c5bbbb7-64be-47ee-8972-c79b5b56cbe5",
    uc_stt: "eca8b2d2-5827-498a-8e3f-37a52e4df0a0",
    uc_embed: "29472ccc-aad6-41cd-a188-7255175250e4",
    uc_revision: "6888f0cd-dbaa-4626-8001-60ffb44a16c1",
    d_diary: "8e5355b7-c1e8-49ba-9de6-f9feccc745f8",
    d_chat: "83a1412c-2f69-4c66-ac6e-b6deeb3b2d7b",
    d_stt: "20b5c350-ad56-4a94-ac40-42b4530593e1",
    d_embed: "c8511b6d-e8ea-4e12-b398-3bd9f116d3fc",
    pv_ko: "248dbec4-ed57-45bc-af95-068153b24efe",
    pv_en: "9903c14e-4b3d-4c25-9107-54e610b5f65a",
    pv_chat: "8241df94-a464-4040-bd60-e6948734d1ca",
    pv_stt: "11cf0dd0-7ed8-486c-bced-f43516bdb5b4",
    p_diary_ko: "85b2fdce-63ee-4c84-bd5f-c7cfbc3e732c",
    p_diary_en: "8b346f72-d11c-4ef2-b55c-f5c0f34bbec2",
    p_chat: "2f468fb1-f651-4ac9-9374-0e68dd0d6f67",
    p_stt: "a40b5507-ac14-4039-9955-82c8b92129c2",
    m_sonnet4: "6918472f-52ff-42b5-bbca-36ca718ebd0e",
    m_gpt5_mini: "00d22769-8fcf-410f-96d5-190949fd2fd3",
    m_opus4: "079982ac-14ad-460d-8261-3732c7fd9f21",
    m_whisper: "c2e93a2c-86a7-46c5-9979-1304f680ff93",
    m_embed: "981220e0-87ce-4b84-b424-0231f66a1fd7"
  }

  @diary_user_template "{% if mode == \"incremental\" %}Here is the existing diary:\n\n{{ existing_diary }}\n\nAppend these new voice transcriptions:\n\n{% for t in transcriptions %}{{ forloop.index }}. {{ t }}\n\n{% endfor %}{% elsif mode == \"edit\" %}Edit the diary below according to the user's request.\n\n{{ user_content }}{% else %}Please write a diary entry based on these voice transcriptions:\n\n{% for t in transcriptions %}{{ forloop.index }}. {{ t }}\n\n{% endfor %}{% endif %}"

  @doc "Name -> UUID."
  @spec id(atom()) :: String.t()
  def id(name), do: Map.fetch!(@ids, name)

  @doc "The whole id map."
  def ids, do: @ids

  @doc "The diary_generation user prompt template."
  def diary_user_template, do: @diary_user_template

  @doc "The reference snapshot (string-keyed map, schema v3)."
  @spec snapshot() :: map()
  def snapshot do
    %{
      "schema_version" => 3,
      "project" => "heydiary",
      "environment" => "production",
      "use_cases" => %{
        "diary_generation" => %{
          "id" => id(:uc_diary),
          "kind" => "chat",
          "input_schema" => [
            %{"name" => "transcriptions", "type" => "list", "required" => true},
            %{"name" => "mode", "type" => "string", "required" => true},
            %{"name" => "existing_diary", "type" => "string", "required" => false},
            %{"name" => "user_content", "type" => "string", "required" => false}
          ],
          "default_params" => %{"temperature" => 0.5},
          "payload_policy" => %{
            "mode" => "full",
            "sample_rate" => 1.0,
            "max_bytes" => 262_144
          }
        },
        "chat_response" => %{
          "id" => id(:uc_chat),
          "kind" => "chat",
          "input_schema" => [%{"name" => "tone", "type" => "string", "required" => false}],
          "default_params" => %{"temperature" => 0.7},
          "payload_policy" => nil
        },
        "voice_transcription" => %{
          "id" => id(:uc_stt),
          "kind" => "text",
          "input_schema" => [],
          "default_params" => %{},
          "payload_policy" => %{
            "mode" => "hash",
            "sample_rate" => 0.1,
            "max_bytes" => 262_144
          }
        },
        "diary_embedding" => %{
          "id" => id(:uc_embed),
          "kind" => "embedding",
          "input_schema" => [],
          "default_params" => %{},
          "payload_policy" => %{"mode" => "none", "sample_rate" => 1.0, "max_bytes" => 262_144}
        },
        "transcript_revision" => %{
          "id" => id(:uc_revision),
          "kind" => "chat",
          "input_schema" => [],
          "default_params" => %{},
          "payload_policy" => nil
        }
      },
      "deployments" => %{
        "diary_generation" => %{
          "id" => id(:d_diary),
          "revision" => 4,
          "model_id" => id(:m_sonnet4),
          "params" => %{"temperature" => 0.4},
          "provider_options" => %{"allow_fallbacks" => false},
          "prompt_pins" => %{"default" => id(:pv_en), "ko" => id(:pv_ko)}
        },
        "chat_response" => %{
          "id" => id(:d_chat),
          "revision" => 2,
          "model_id" => id(:m_gpt5_mini),
          "params" => %{"max_tokens" => 1024},
          "provider_options" => %{},
          "prompt_pins" => %{"default" => id(:pv_chat)}
        },
        "voice_transcription" => %{
          "id" => id(:d_stt),
          "revision" => 1,
          "model_id" => id(:m_whisper),
          "params" => %{},
          "provider_options" => %{},
          "prompt_pins" => %{"default" => id(:pv_stt)}
        },
        "diary_embedding" => %{
          "id" => id(:d_embed),
          "revision" => 1,
          "model_id" => id(:m_embed),
          "params" => %{},
          "provider_options" => %{},
          "prompt_pins" => %{}
        }
      },
      "prompt_versions" => %{
        id(:pv_en) => %{
          "id" => id(:pv_en),
          "prompt_id" => id(:p_diary_en),
          "number" => 2,
          "engine" => "liquid",
          "messages" => [
            %{"role" => "system", "content" => "You write diaries from voice transcriptions."},
            %{"role" => "user", "content" => @diary_user_template}
          ],
          "text_template" => nil
        },
        id(:pv_ko) => %{
          "id" => id(:pv_ko),
          "prompt_id" => id(:p_diary_ko),
          "number" => 3,
          "engine" => "liquid",
          "messages" => [
            %{
              "role" => "system",
              "content" => "You write diaries from voice transcriptions, in Korean."
            },
            %{"role" => "user", "content" => @diary_user_template}
          ],
          "text_template" => nil
        },
        id(:pv_chat) => %{
          "id" => id(:pv_chat),
          "prompt_id" => id(:p_chat),
          "number" => 1,
          "engine" => "liquid",
          "messages" => [
            %{
              "role" => "system",
              "content" =>
                "You are a warm diary companion.{% if tone %} Tone: {{ tone }}.{% endif %}"
            }
          ],
          "text_template" => nil
        },
        id(:pv_stt) => %{
          "id" => id(:pv_stt),
          "prompt_id" => id(:p_stt),
          "number" => 1,
          "engine" => "raw",
          "messages" => nil,
          "text_template" => "Hello. Today's diary {{ verbatim }}"
        }
      },
      "models" => %{
        id(:m_sonnet4) => %{
          "id" => id(:m_sonnet4),
          "provider" => "openrouter",
          "model_id" => "anthropic/claude-sonnet-4",
          "display_name" => "Claude Sonnet 4",
          "metadata" => %{"description_key" => "chat_model.sonnet4"},
          "provider_options" => %{"only" => ["Anthropic"]},
          "capabilities" => ["tools", "streaming"],
          "pricing" => %{
            "input_per_m" => 3.0,
            "output_per_m" => 15.0,
            "currency" => "USD",
            "unit" => "token"
          },
          "status" => "active"
        },
        id(:m_gpt5_mini) => %{
          "id" => id(:m_gpt5_mini),
          "provider" => "openrouter",
          "model_id" => "openai/gpt-5-mini",
          "display_name" => "GPT-5 mini",
          "metadata" => %{"description_key" => "chat_model.gpt5_mini"},
          "provider_options" => %{"only" => ["OpenAI"]},
          "capabilities" => [],
          "pricing" => %{},
          "status" => "active"
        },
        id(:m_opus4) => %{
          "id" => id(:m_opus4),
          "provider" => "openrouter",
          "model_id" => "anthropic/claude-opus-4",
          "display_name" => "Claude Opus 4",
          "metadata" => %{"description_key" => "chat_model.opus4"},
          "provider_options" => %{"only" => ["Anthropic"]},
          "capabilities" => [],
          "pricing" => %{},
          "status" => "deprecated"
        },
        id(:m_whisper) => %{
          "id" => id(:m_whisper),
          "provider" => "groq",
          "model_id" => "whisper-large-v3",
          "display_name" => "Whisper large v3",
          "metadata" => %{},
          "provider_options" => %{},
          "capabilities" => [],
          "pricing" => %{"input_per_m" => 0.111, "unit" => "audio_second"},
          "status" => "active"
        },
        id(:m_embed) => %{
          "id" => id(:m_embed),
          "provider" => "openai",
          "model_id" => "text-embedding-3-small",
          "display_name" => "Embedding 3 small",
          "metadata" => %{},
          "provider_options" => %{},
          "capabilities" => [],
          "pricing" => %{},
          "status" => "active"
        }
      }
    }
  end

  @doc "The decoded snapshot data."
  @spec snapshot_data() :: PromptOnSDK.SnapshotData.t()
  def snapshot_data do
    {:ok, data, []} = PromptOnSDK.SnapshotData.decode(snapshot())
    data
  end
end
