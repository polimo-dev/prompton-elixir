defmodule PromptOnSDK.SnapshotDataTest do
  @moduledoc "Snapshot v3 decoding contract; v1/v2 are no longer read."

  use ExUnit.Case, async: true

  alias PromptOnSDK.{Fixtures, SnapshotData}

  describe "decode/1" do
    test "decodes the reference snapshot with no warnings" do
      assert {:ok, data, []} = SnapshotData.decode(Fixtures.snapshot())

      assert data.schema_version == 3
      assert data.project == "heydiary"
      assert data.environment == "production"
      assert map_size(data.use_cases) == 5
      assert map_size(data.deployments) == 4
      assert map_size(data.prompt_versions) == 4
      assert map_size(data.models) == 5
    end

    test "deployments decode to pins" do
      {:ok, data, []} = SnapshotData.decode(Fixtures.snapshot())
      deployment = SnapshotData.deployment(data, "diary_generation")

      assert deployment.id == Fixtures.id(:d_diary)
      assert deployment.use_case_key == "diary_generation"
      assert deployment.revision == 4
      assert deployment.model_id == Fixtures.id(:m_sonnet4)
      assert deployment.params == %{"temperature" => 0.4}
      assert deployment.provider_options == %{"allow_fallbacks" => false}

      assert deployment.prompt_pins == %{
               "default" => Fixtures.id(:pv_en),
               "ko" => Fixtures.id(:pv_ko)
             }
    end

    test "the deployment is attached to its use case" do
      {:ok, data, []} = SnapshotData.decode(Fixtures.snapshot())

      assert data.use_cases["diary_generation"].deployment.id == Fixtures.id(:d_diary)
      assert data.use_cases["transcript_revision"].deployment == nil
      assert SnapshotData.deployment(data, :chat_response).id == Fixtures.id(:d_chat)
      assert SnapshotData.deployment(data, "nope") == nil
    end

    test "enums become atoms, opaque maps stay string-keyed" do
      {:ok, data, []} = SnapshotData.decode(Fixtures.snapshot())

      assert data.use_cases["diary_generation"].kind == :chat
      assert data.use_cases["diary_embedding"].kind == :embedding
      assert data.prompt_versions[Fixtures.id(:pv_stt)].engine == :raw
      assert data.models[Fixtures.id(:m_sonnet4)].provider == :openrouter
      assert data.models[Fixtures.id(:m_opus4)].status == :deprecated
      assert data.use_cases["diary_generation"].default_params == %{"temperature" => 0.5}
      assert data.use_cases["diary_generation"].payload_policy.mode == :full
    end

    test "atom-keyed maps (hand-written test snapshots) decode too" do
      map = %{
        schema_version: 3,
        environment: "staging",
        use_cases: %{"greet" => %{id: "u1", kind: "chat"}},
        deployments: %{
          "greet" => %{id: "d1", revision: 1, model_id: "m1", prompt_pins: %{"default" => "p1"}}
        },
        prompt_versions: %{"p1" => %{id: "p1", messages: [%{role: "system", content: "hi"}]}},
        models: %{"m1" => %{id: "m1", model_id: "openai/gpt-5-mini"}}
      }

      assert {:ok, data, []} = SnapshotData.decode(map)
      assert data.environment == "staging"
      assert data.deployments["greet"].prompt_pins == %{"default" => "p1"}
    end

    test "decode_json/1 round-trips" do
      json = Jason.encode!(Fixtures.snapshot())
      assert {:ok, data, []} = SnapshotData.decode_json(json)
      assert data.deployments["chat_response"].model_id == Fixtures.id(:m_gpt5_mini)
    end

    test "a %SnapshotData{} passes through" do
      data = Fixtures.snapshot_data()
      assert {:ok, ^data, []} = SnapshotData.decode(data)
    end
  end

  describe "schema versions" do
    test "v1 and v2 snapshots are refused" do
      for version <- [1, 2] do
        map = Map.put(Fixtures.snapshot(), "schema_version", version)
        assert {:error, {:unsupported_schema_version, ^version}} = SnapshotData.decode(map)
      end
    end

    test "a newer version decodes the fields it knows, with a warning" do
      map = Map.put(Fixtures.snapshot(), "schema_version", 4)

      assert {:ok, data, warnings} = SnapshotData.decode(map)
      assert warnings == [{:unknown_schema_version, 4}]
      assert data.deployments["diary_generation"].revision == 4
    end

    test "a missing version is v3 when `deployments` is present" do
      map = Map.delete(Fixtures.snapshot(), "schema_version")
      assert {:ok, data, []} = SnapshotData.decode(map)
      assert data.schema_version == 3
    end

    test "a missing version with no deployments is an error" do
      assert {:error, {:invalid_snapshot, message}} =
               SnapshotData.decode(%{"use_cases" => %{}})

      assert message =~ "schema_version"
    end

    test "a non-integer version is an error" do
      assert {:error, {:invalid_snapshot, message}} =
               SnapshotData.decode(Map.put(Fixtures.snapshot(), "schema_version", "3"))

      assert message =~ "positive integer"
    end
  end

  describe "malformed input" do
    test "use_cases is required" do
      assert {:error, {:invalid_snapshot, message}} =
               SnapshotData.decode(%{"schema_version" => 3})

      assert message =~ "use_cases is required"
    end

    test "a non-map top level is refused" do
      assert {:error, {:invalid_snapshot, _}} = SnapshotData.decode("nope")
      assert {:error, {:invalid_snapshot, _}} = SnapshotData.decode_json("[]")
      assert {:error, {:invalid_json, _}} = SnapshotData.decode_json("{oops")
    end

    test "a broken deployment entry is warned about, the rest still decodes" do
      map = put_in(Fixtures.snapshot(), ["deployments", "chat_response"], "nope")

      assert {:ok, data, warnings} = SnapshotData.decode(map)
      assert {:invalid_deployment, {"chat_response", "nope"}} in warnings
      assert data.deployments["diary_generation"].revision == 4
      refute Map.has_key?(data.deployments, "chat_response")
    end

    test "broken prompt_pins are warned about" do
      map = put_in(Fixtures.snapshot(), ["deployments", "chat_response", "prompt_pins"], "nope")

      assert {:ok, data, warnings} = SnapshotData.decode(map)
      assert {:invalid_prompt_pins, {"chat_response", "nope"}} in warnings
      assert data.deployments["chat_response"].prompt_pins == %{}
    end

    test "an unknown kind is kept as an atom with a warning" do
      map = put_in(Fixtures.snapshot(), ["use_cases", "chat_response", "kind"], "vision")

      assert {:ok, data, warnings} = SnapshotData.decode(map)
      assert {:unknown_kind, "vision"} in warnings
      assert data.use_cases["chat_response"].kind == :vision
    end
  end
end
