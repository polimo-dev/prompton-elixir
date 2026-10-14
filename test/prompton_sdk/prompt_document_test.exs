defmodule PromptOnSDK.PromptDocumentTest do
  @moduledoc "Prompt document v4 decoding contract; v1-v3 are no longer read."

  use ExUnit.Case, async: true

  alias PromptOnSDK.{Fixtures, PromptDocument}

  describe "decode/1" do
    test "decodes the reference prompt document with no warnings" do
      assert {:ok, data, []} = PromptDocument.decode(Fixtures.snapshot())

      assert %PromptDocument{} = data
      assert data.schema_version == 5
      assert data.project == "heydiary"
      assert data.environment == "production"
      assert map_size(data.prompts) == 5
      assert map_size(data.deployments) == 4
      assert map_size(data.prompt_versions) == 4
      assert map_size(data.models) == 5
    end

    test "deployments decode to pins" do
      {:ok, data, []} = PromptDocument.decode(Fixtures.snapshot())
      deployment = PromptDocument.deployment(data, "diary_generation")

      assert deployment.id == Fixtures.id(:d_diary)
      assert deployment.prompt_key == "diary_generation"
      assert deployment.revision == "v2026.09.30-4"
      assert deployment.model_id == Fixtures.id(:m_sonnet4)
      assert deployment.params == %{"temperature" => 0.4}
      assert deployment.provider_options == %{"allow_fallbacks" => false}

      assert deployment.template_pins == %{
               "default" => Fixtures.id(:pv_en),
               "ko" => Fixtures.id(:pv_ko)
             }
    end

    test "the deployment is attached to its prompt" do
      {:ok, data, []} = PromptDocument.decode(Fixtures.snapshot())

      assert data.prompts["diary_generation"].deployment.id == Fixtures.id(:d_diary)
      assert data.prompts["transcript_revision"].deployment == nil
      assert PromptDocument.deployment(data, :chat_response).id == Fixtures.id(:d_chat)
      assert PromptDocument.deployment(data, "nope") == nil
    end

    test "enums become atoms, opaque maps stay string-keyed" do
      {:ok, data, []} = PromptDocument.decode(Fixtures.snapshot())

      assert data.prompts["diary_generation"].kind == :chat
      assert data.prompts["diary_embedding"].kind == :embedding
      assert data.prompt_versions[Fixtures.id(:pv_stt)].engine == :raw
      assert data.models[Fixtures.id(:m_sonnet4)].provider == :openrouter
      assert data.models[Fixtures.id(:m_opus4)].status == :deprecated
      assert data.prompts["diary_generation"].default_params == %{"temperature" => 0.5}
      assert data.prompts["diary_generation"].payload_policy.mode == :full
    end

    test "atom-keyed maps (hand-written test documents) decode too" do
      map = %{
        schema_version: 5,
        environment: "staging",
        prompts: %{"greet" => %{id: "u1", kind: "chat"}},
        deployments: %{
          "greet" => %{
            id: "d1",
            revision: "v2026.09.30-1",
            model_id: "m1",
            template_pins: %{"default" => "p1"}
          }
        },
        prompt_versions: %{"p1" => %{id: "p1", messages: [%{role: "system", content: "hi"}]}},
        models: %{"m1" => %{id: "m1", model_id: "openai/gpt-5-mini"}}
      }

      assert {:ok, data, []} = PromptDocument.decode(map)
      assert data.environment == "staging"
      assert data.deployments["greet"].template_pins == %{"default" => "p1"}
    end

    test "decode_json/1 round-trips" do
      json = Jason.encode!(Fixtures.snapshot())
      assert {:ok, data, []} = PromptDocument.decode_json(json)
      assert %PromptDocument{} = data
      assert data.deployments["chat_response"].model_id == Fixtures.id(:m_gpt5_mini)
    end

    test "a decoded prompt document passes through" do
      data = Fixtures.snapshot_data()
      assert {:ok, ^data, []} = PromptDocument.decode(data)
    end
  end

  describe "schema versions" do
    test "v1, v2, and v3 documents are refused" do
      for version <- [1, 2, 3] do
        map = Map.put(Fixtures.snapshot(), "schema_version", version)
        assert {:error, {:unsupported_schema_version, ^version}} = PromptDocument.decode(map)
      end
    end

    test "schema v8 readable resource keys decode without resource UUIDs" do
      map = %{
        "schema_version" => 8,
        "project" => "helpdesk",
        "environment" => "production",
        "prompts" => %{
          "support_reply" => %{"kind" => "chat", "default_params" => %{"temperature" => 0.5}}
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

      assert {:ok, data, []} = PromptDocument.decode(map)
      assert data.schema_version == 8
      assert data.deployments["support_reply"].id == nil
      assert data.deployments["support_reply"].model_id == "openrouter:openai/gpt-4o-mini"
      assert data.deployments["support_reply"].template_pins == %{"default" => "support_reply@2"}
      assert data.prompt_versions["support_reply@2"].id == "support_reply@2"
      assert data.prompt_versions["support_reply@2"].prompt_template_id == "support_reply"
      assert data.models["openrouter:openai/gpt-4o-mini"].model_id == "openai/gpt-4o-mini"
    end

    test "schema v8 requires strict readable resource references" do
      map = %{
        "schema_version" => 8,
        "prompts" => %{"support_reply" => %{"kind" => "chat"}},
        "deployments" => %{
          "support_reply" => %{
            "provider" => "openrouter",
            "model" => "openai/gpt-4o-mini",
            "prompt_version" => 2
          }
        },
        "prompt_versions" => %{
          "support_reply@2" => %{"prompt" => "support_reply", "number" => 2, "kind" => "chat"}
        },
        "models" => %{
          "openrouter:openai/gpt-4o-mini" => %{
            "provider" => "openrouter",
            "model" => "openai/gpt-4o-mini"
          }
        }
      }

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

    test "a newer version is refused" do
      map = Map.put(Fixtures.snapshot(), "schema_version", 9)

      assert {:error, {:unsupported_schema_version, 9}} = PromptDocument.decode(map)
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
               PromptDocument.decode(Map.put(Fixtures.snapshot(), "schema_version", "4"))

      assert message =~ "positive integer"
    end
  end

  describe "malformed input" do
    test "prompts is required" do
      assert {:error, {:invalid_prompt_document, message}} =
               PromptDocument.decode(%{"schema_version" => 5})

      assert message =~ "prompts is required"
    end

    test "a non-map top level is refused" do
      assert {:error, {:invalid_prompt_document, _}} = PromptDocument.decode("nope")
      assert {:error, {:invalid_prompt_document, _}} = PromptDocument.decode_json("[]")
      assert {:error, {:invalid_json, _}} = PromptDocument.decode_json("{oops")
    end

    test "a broken deployment entry is warned about, the rest still decodes" do
      map = put_in(Fixtures.snapshot(), ["deployments", "chat_response"], "nope")

      assert {:ok, data, warnings} = PromptDocument.decode(map)
      assert {:invalid_deployment, {"chat_response", "nope"}} in warnings
      assert data.deployments["diary_generation"].revision == "v2026.09.30-4"
      refute Map.has_key?(data.deployments, "chat_response")
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

    test "broken template_pins are warned about" do
      map = put_in(Fixtures.snapshot(), ["deployments", "chat_response", "template_pins"], "nope")

      assert {:ok, data, warnings} = PromptDocument.decode(map)
      assert {:invalid_template_pins, {"chat_response", "nope"}} in warnings
      assert data.deployments["chat_response"].template_pins == %{}
    end

    test "an unknown kind falls back to chat with a warning" do
      map = put_in(Fixtures.snapshot(), ["prompts", "chat_response", "kind"], "vision")

      assert {:ok, data, warnings} = PromptDocument.decode(map)
      assert {:unknown_kind, "vision"} in warnings
      assert data.prompts["chat_response"].kind == :chat
    end
  end
end
