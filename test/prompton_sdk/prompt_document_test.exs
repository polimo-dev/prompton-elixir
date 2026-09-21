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
      assert deployment.revision == 4
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
          "greet" => %{id: "d1", revision: 1, model_id: "m1", template_pins: %{"default" => "p1"}}
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

    test "a newer version is refused" do
      map = Map.put(Fixtures.snapshot(), "schema_version", 7)

      assert {:error, {:unsupported_schema_version, 7}} = PromptDocument.decode(map)
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
      assert data.deployments["diary_generation"].revision == 4
      refute Map.has_key?(data.deployments, "chat_response")
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
