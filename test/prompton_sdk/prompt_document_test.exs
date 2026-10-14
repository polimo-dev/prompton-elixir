defmodule PromptOnSDK.PromptDocumentTest do
  @moduledoc "Schema v1 prompt document decoding contract."

  use ExUnit.Case, async: true

  alias PromptOnSDK.{Fixtures, PromptDocument}

  describe "decode/1" do
    test "decodes the reference prompt document with no warnings" do
      assert {:ok, data, []} = PromptDocument.decode(Fixtures.snapshot())

      assert %PromptDocument{} = data
      assert data.schema_version == 1
      assert data.project == "heydiary"
      assert data.environment == "production"
      assert map_size(data.prompts) == 5
      assert map_size(data.deployments) == 3
      assert map_size(data.prompt_versions) == 3
      assert map_size(data.models) == 5
    end

    test "deployments decode to readable default pins" do
      {:ok, data, []} = PromptDocument.decode(Fixtures.snapshot())
      deployment = PromptDocument.deployment(data, "diary_generation")

      assert deployment.id == nil
      assert deployment.prompt_key == "diary_generation"
      assert deployment.revision == "v2026.09.30-4"
      assert deployment.model_id == "openrouter:anthropic/claude-sonnet-4"
      assert deployment.params == %{"temperature" => 0.4}
      assert deployment.provider_options == %{"allow_fallbacks" => false}
      assert deployment.template_pins == %{"default" => "diary_generation@2"}
    end

    test "the deployment is attached to its prompt" do
      {:ok, data, []} = PromptDocument.decode(Fixtures.snapshot())

      assert data.prompts["diary_generation"].deployment.id == nil
      assert data.prompts["transcript_revision"].deployment == nil
      assert PromptDocument.deployment(data, :chat_response).id == nil
      assert PromptDocument.deployment(data, "nope") == nil
    end

    test "enums become atoms, opaque maps stay string-keyed" do
      {:ok, data, []} = PromptDocument.decode(Fixtures.snapshot())

      assert data.prompts["diary_generation"].kind == :chat
      assert data.prompts["diary_embedding"].kind == :embedding
      assert data.prompt_versions["voice_transcription@1"].engine == :raw
      assert data.models["openrouter:anthropic/claude-sonnet-4"].provider == :openrouter
      assert data.models["openrouter:anthropic/claude-opus-4"].status == :deprecated
      assert data.prompts["diary_generation"].default_params == %{"temperature" => 0.5}
      assert data.prompts["diary_generation"].payload_policy.mode == :full
    end

    test "atom-keyed maps (hand-written test documents) decode too" do
      map = %{
        schema_version: 1,
        environment: "staging",
        prompts: %{"greet" => %{kind: "chat", variables: []}},
        deployments: %{
          "greet" => %{
            revision: "v2026.09.30-1",
            provider: "openrouter",
            model: "openai/gpt-5-mini",
            prompt_version: 1
          }
        },
        prompt_versions: %{
          "greet@1" => %{
            prompt: "greet",
            number: 1,
            kind: "chat",
            messages: [%{role: "system", content: "hi"}]
          }
        },
        models: %{
          "openrouter:openai/gpt-5-mini" => %{
            provider: "openrouter",
            model: "openai/gpt-5-mini"
          }
        }
      }

      assert {:ok, data, []} = PromptDocument.decode(map)
      assert data.environment == "staging"
      assert data.deployments["greet"].template_pins == %{"default" => "greet@1"}
    end

    test "decode_json/1 round-trips" do
      json = Jason.encode!(Fixtures.snapshot())
      assert {:ok, data, []} = PromptDocument.decode_json(json)
      assert %PromptDocument{} = data
      assert data.deployments["chat_response"].model_id == "openrouter:openai/gpt-5-mini"
    end

    test "a decoded prompt document passes through" do
      data = Fixtures.snapshot_data()
      assert {:ok, ^data, []} = PromptDocument.decode(data)
    end
  end

  describe "schema versions" do
    test "schema v1 readable resource keys decode without resource UUIDs" do
      map = readable_bundle()

      assert {:ok, data, []} = PromptDocument.decode(map)
      assert data.schema_version == 1
      assert data.deployments["support_reply"].id == nil
      assert data.deployments["support_reply"].model_id == "openrouter:openai/gpt-4o-mini"
      assert data.deployments["support_reply"].template_pins == %{"default" => "support_reply@2"}
      assert data.prompt_versions["support_reply@2"].id == "support_reply@2"
      assert data.prompt_versions["support_reply@2"].prompt_template_id == "support_reply"
      assert data.models["openrouter:openai/gpt-4o-mini"].model_id == "openai/gpt-4o-mini"
    end

    test "schema v1 single prompt envelope decodes through the normal document view" do
      map = single_prompt()

      assert {:ok, data, []} = PromptDocument.decode(map)
      assert data.schema_version == 1
      assert data.prompts["support_reply"].key == "support_reply"
      assert data.deployments["support_reply"].model_id == "openrouter:openai/gpt-4o-mini"
      assert data.deployments["support_reply"].template_pins == %{"default" => "support_reply@2"}
      assert data.prompt_versions["support_reply@2"].prompt_template_id == "support_reply"
      assert data.models["openrouter:openai/gpt-4o-mini"].model_id == "openai/gpt-4o-mini"
    end

    test "schema v1 single prompt envelope rejects mixed and mismatched identities" do
      map = single_prompt()
      assert {:ok, _data, []} = PromptDocument.decode(map)

      mixed = Map.put(map, "prompts", %{})
      assert {:error, {:invalid_prompt_document, message}} = PromptDocument.decode(mixed)
      assert message =~ "must not include prompts"

      mixed_null = Map.put(map, "prompts", nil)
      assert {:error, {:invalid_prompt_document, message}} = PromptDocument.decode(mixed_null)
      assert message =~ "must not include prompts"

      partial_mixed = Map.put(readable_bundle(), "deployment", %{})
      assert {:error, {:invalid_prompt_document, message}} = PromptDocument.decode(partial_mixed)
      assert message =~ "must not include prompts"

      bad_prompt = put_in(map, ["prompt_version", "prompt"], "other")
      assert {:error, {:invalid_prompt_document, message}} = PromptDocument.decode(bad_prompt)
      assert message =~ "prompt_version.prompt other"

      bad_version = put_in(map, ["deployment", "prompt_version"], 3)
      assert {:error, {:invalid_prompt_document, message}} = PromptDocument.decode(bad_version)
      assert message =~ "deployment.prompt_version 3"

      bad_model = put_in(map, ["deployment", "model"], "openai/missing")
      assert {:error, {:invalid_prompt_document, message}} = PromptDocument.decode(bad_model)
      assert message =~ "must match model"
    end

    test "schema v1 requires strict readable resource references" do
      map = readable_bundle()
      assert {:ok, _data, []} = PromptDocument.decode(map)

      string_pin = put_in(map, ["deployments", "support_reply", "prompt_version"], "2")
      assert {:error, {:invalid_prompt_document, message}} = PromptDocument.decode(string_pin)
      assert message =~ "deployments.support_reply.prompt_version"
      assert message =~ "positive integer"

      bool_pin = put_in(map, ["deployments", "support_reply", "prompt_version"], true)
      assert {:error, {:invalid_prompt_document, message}} = PromptDocument.decode(bool_pin)
      assert message =~ "positive integer"

      bad_version_key =
        map
        |> update_in(["prompt_versions"], fn versions ->
          version = Map.fetch!(versions, "support_reply@2")
          %{"other@2" => version}
        end)

      assert {:error, {:invalid_prompt_document, message}} =
               PromptDocument.decode(bad_version_key)

      assert message =~ "prompt_versions key other@2"

      missing_model = put_in(map, ["deployments", "support_reply", "model"], "openai/missing")
      assert {:error, {:invalid_prompt_document, message}} = PromptDocument.decode(missing_model)
      assert message =~ "missing model openrouter:openai/missing"

      colon_model =
        map
        |> put_in(["deployments", "support_reply", "model"], "vendor:family/model")
        |> put_in(["models"], %{
          "openrouter:vendor:family/model" => %{
            "provider" => "openrouter",
            "model" => "vendor:family/model"
          }
        })

      assert {:ok, _data, []} = PromptDocument.decode(colon_model)
    end

    test "any non-v1 version is refused" do
      for version <- [2, 3, 5, 8, 9, 10] do
        map = Map.put(Fixtures.snapshot(), "schema_version", version)
        assert {:error, {:unsupported_schema_version, ^version}} = PromptDocument.decode(map)
      end
    end

    test "schema_version is required even when `deployments` is present" do
      map = Map.delete(Fixtures.snapshot(), "schema_version")
      assert {:error, {:invalid_prompt_document, message}} = PromptDocument.decode(map)
      assert message =~ "schema_version is required"
    end

    test "schema_version is required before other required fields are checked" do
      assert {:error, {:invalid_prompt_document, message}} =
               PromptDocument.decode(%{"prompts" => %{}})

      assert message =~ "schema_version"
    end

    test "a non-integer version is an error" do
      assert {:error, {:invalid_prompt_document, message}} =
               PromptDocument.decode(Map.put(Fixtures.snapshot(), "schema_version", "1"))

      assert message =~ "positive integer"
    end
  end

  describe "malformed input" do
    test "prompts is required" do
      assert {:error, {:invalid_prompt_document, message}} =
               PromptDocument.decode(%{"schema_version" => 1})

      assert message =~ "prompts is required"
    end

    test "a discovery list is not loadable configuration" do
      map = %{"schema_version" => 1, "prompts" => [%{"key" => "support_reply", "kind" => "chat"}]}
      assert {:error, {:invalid_prompt_document, message}} = PromptDocument.decode(map)
      assert message =~ "discovery-only"
    end

    test "aggregate bundles require all schema v1 collection maps" do
      base = readable_bundle()

      for key <- ~w(deployments prompt_versions models) do
        missing = Map.delete(base, key)
        assert {:error, {:invalid_prompt_document, message}} = PromptDocument.decode(missing)
        assert message =~ "#{key} is required"

        list_value = Map.put(base, key, [])
        assert {:error, {:invalid_prompt_document, message}} = PromptDocument.decode(list_value)
        assert message =~ "#{key} must be an object"
      end

      empty = %{
        "schema_version" => 1,
        "project" => "empty",
        "environment" => "production",
        "prompts" => %{},
        "deployments" => %{},
        "prompt_versions" => %{},
        "models" => %{}
      }

      assert {:ok, data, []} = PromptDocument.decode(empty)
      assert data.prompts == %{}
    end

    test "a non-map top level is refused" do
      assert {:error, {:invalid_prompt_document, _}} = PromptDocument.decode("nope")
      assert {:error, {:invalid_prompt_document, _}} = PromptDocument.decode_json("[]")
      assert {:error, {:invalid_json, _}} = PromptDocument.decode_json("{oops")
    end

    test "a broken deployment entry is rejected before decoding" do
      map = put_in(Fixtures.snapshot(), ["deployments", "chat_response"], "nope")

      assert {:error, {:invalid_prompt_document, message}} = PromptDocument.decode(map)
      assert message =~ "deployments.chat_response must be an object"
    end

    test "a revision label with a trailing newline is rejected" do
      map =
        put_in(
          Fixtures.snapshot(),
          ["deployments", "chat_response", "revision"],
          "v2026.09.30-2\n"
        )

      assert {:ok, data, warnings} = PromptDocument.decode(map)
      assert {:invalid_revision, "v2026.09.30-2\n"} in warnings
      assert data.deployments["chat_response"].revision == nil
    end

    test "an invalid deployment prompt_version warns during decoding" do
      map = put_in(Fixtures.snapshot(), ["deployments", "chat_response", "prompt_version"], nil)

      assert {:error, {:invalid_prompt_document, message}} = PromptDocument.decode(map)
      assert message =~ "prompt_version is required"
    end

    test "an unknown kind falls back to chat with a warning" do
      map = put_in(Fixtures.snapshot(), ["prompts", "chat_response", "kind"], "vision")

      assert {:ok, data, warnings} = PromptDocument.decode(map)
      assert {:unknown_kind, "vision"} in warnings
      assert data.prompts["chat_response"].kind == :chat
    end
  end

  defp readable_bundle do
    %{
      "schema_version" => 1,
      "project" => "helpdesk",
      "environment" => "production",
      "prompts" => %{
        "support_reply" => %{
          "kind" => "chat",
          "variables" => [
            %{"name" => "question", "type" => "string", "required" => true, "example" => "Hi"}
          ],
          "default_params" => %{"temperature" => 0.5}
        }
      },
      "deployments" => %{
        "support_reply" => %{
          "revision" => "v2026.09.30-3",
          "provider" => "openrouter",
          "model" => "openai/gpt-4o-mini",
          "prompt_version" => 2,
          "params" => %{"temperature" => 0.3}
        }
      },
      "prompt_versions" => %{
        "support_reply@2" => %{
          "prompt" => "support_reply",
          "number" => 2,
          "kind" => "chat",
          "engine" => "liquid",
          "messages" => [%{"role" => "user", "content" => "{{ question }}"}]
        }
      },
      "models" => %{
        "openrouter:openai/gpt-4o-mini" => %{
          "provider" => "openrouter",
          "model" => "openai/gpt-4o-mini",
          "status" => "active"
        }
      }
    }
  end

  defp single_prompt do
    %{
      "schema_version" => 1,
      "project" => "helpdesk",
      "environment" => "production",
      "prompt" => %{
        "key" => "support_reply",
        "kind" => "chat",
        "variables" => [%{"name" => "question", "type" => "string", "required" => true}],
        "default_params" => %{"temperature" => 0.5}
      },
      "deployment" => %{
        "revision" => "v2026.09.30-3",
        "provider" => "openrouter",
        "model" => "openai/gpt-4o-mini",
        "prompt_version" => 2,
        "params" => %{"temperature" => 0.3}
      },
      "prompt_version" => %{
        "prompt" => "support_reply",
        "number" => 2,
        "kind" => "chat",
        "engine" => "liquid",
        "messages" => [%{"role" => "user", "content" => "{{ question }}"}]
      },
      "model" => %{
        "provider" => "openrouter",
        "model" => "openai/gpt-4o-mini",
        "status" => "active"
      }
    }
  end
end
