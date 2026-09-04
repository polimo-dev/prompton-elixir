defmodule PromptOnSDK.ResolverTest do
  @moduledoc """
  Resolution algorithm (snapshot v3): a deployment is a pin, not a router.
  With no rules, conditions, targets, or weights, only three things need verifying: (1) prompt name
  selection, (2) parameter merging, (3) the error/warning contract for what is missing (use case,
  deployment, prompt, model).
  """

  use ExUnit.Case, async: true

  alias PromptOnSDK.{Fixtures, Resolver, SnapshotData}

  setup do
    %{snapshot: Fixtures.snapshot_data()}
  end

  describe "prompt selection" do
    test "no :prompt resolves the \"default\" pin", %{snapshot: snapshot} do
      assert {:ok, r} = Resolver.resolve(snapshot, "diary_generation")

      assert r.prompt == "default"
      assert r.prompt_version_id == Fixtures.id(:pv_en)
      assert r.prompt_version_number == 2
      assert r.deployment_id == Fixtures.id(:d_diary)
      assert r.deployment_revision == 4

      assert [%{role: "system", content: "You write diaries from voice transcriptions."} | _] =
               r.messages
    end

    test ":prompt selects the named pin (this is how language branching works now)", %{
      snapshot: snapshot
    } do
      assert {:ok, r} = Resolver.resolve(snapshot, "diary_generation", prompt: "ko")

      assert r.prompt == "ko"
      assert r.prompt_version_id == Fixtures.id(:pv_ko)
      assert r.prompt_version_number == 3

      assert [%{content: "You write diaries from voice transcriptions, in Korean."} | _] =
               r.messages
    end

    test "an atom prompt name is accepted", %{snapshot: snapshot} do
      assert {:ok, r} = Resolver.resolve(snapshot, :diary_generation, prompt: :ko)
      assert r.prompt == "ko"
    end

    test "a name the deployment does not pin is an error, never a silent default", %{
      snapshot: snapshot
    } do
      assert {:error, :unknown_prompt} =
               Resolver.resolve(snapshot, "diary_generation", prompt: "ja")

      assert {:error, :unknown_prompt} =
               Resolver.resolve(snapshot, "chat_response", prompt: "ko")
    end

    test "prompt_names/2 lists the pinned names", %{snapshot: snapshot} do
      assert {:ok, ["default", "ko"]} = Resolver.prompt_names(snapshot, "diary_generation")
      assert {:ok, ["default"]} = Resolver.prompt_names(snapshot, "chat_response")
      assert {:ok, []} = Resolver.prompt_names(snapshot, "diary_embedding")
      assert {:ok, []} = Resolver.prompt_names(snapshot, "transcript_revision")
      assert {:error, :unknown_use_case} = Resolver.prompt_names(snapshot, "nope")
    end
  end

  describe "kinds" do
    test "text use case carries text_template and no messages", %{snapshot: snapshot} do
      assert {:ok, r} = Resolver.resolve(snapshot, "voice_transcription")

      assert r.kind == :text
      assert r.text_template == "Hello. Today's diary {{ verbatim }}"
      assert r.messages == nil
      assert r.engine == :raw
    end

    test "embedding use case has no prompt at all and ignores :prompt", %{snapshot: snapshot} do
      assert {:ok, r} = Resolver.resolve(snapshot, "diary_embedding", prompt: "ko")

      assert r.kind == :embedding
      assert r.prompt == nil
      assert r.prompt_version_id == nil
      assert r.messages == nil
      assert r.text_template == nil
      assert r.model == "text-embedding-3-small"
    end
  end

  describe "effective params" do
    test "deployment params/provider_options override use case and model defaults", %{
      snapshot: snapshot
    } do
      assert {:ok, r} = Resolver.resolve(snapshot, "diary_generation")

      # use case default_params temperature 0.5 ⊕ deployment 0.4
      assert r.effective_params == %{"temperature" => 0.4}
      # model provider_options only:[Anthropic] ⊕ deployment allow_fallbacks:false
      assert r.effective_provider_options == %{
               "only" => ["Anthropic"],
               "allow_fallbacks" => false
             }

      assert r.model == "anthropic/claude-sonnet-4"
      assert r.model_id == Fixtures.id(:m_sonnet4)
      assert r.provider == :openrouter
    end

    test "use case defaults survive when the deployment adds a different key", %{
      snapshot: snapshot
    } do
      assert {:ok, r} = Resolver.resolve(snapshot, "chat_response")
      assert r.effective_params == %{"temperature" => 0.7, "max_tokens" => 1024}
    end
  end

  describe "errors and warnings" do
    test "unknown use case", %{snapshot: snapshot} do
      assert {:error, :unknown_use_case} = Resolver.resolve(snapshot, "nope")
    end

    test "a use case with no deployment is unresolved", %{snapshot: snapshot} do
      assert {:error, :unresolved} = Resolver.resolve(snapshot, "transcript_revision")
    end

    test "a pin pointing at a missing prompt version warns and leaves the field nil" do
      snapshot =
        Fixtures.snapshot()
        |> update_in(["prompt_versions"], &Map.delete(&1, Fixtures.id(:pv_en)))

      {:ok, data, _} = SnapshotData.decode(snapshot)

      assert {:ok, r} = Resolver.resolve(data, "diary_generation")
      assert r.prompt_version_id == nil
      assert r.messages == nil
      assert r.warnings == [{:missing_prompt_version, Fixtures.id(:pv_en)}]
    end

    test "a deployment pointing at a missing model warns and leaves the field nil" do
      snapshot =
        Fixtures.snapshot() |> update_in(["models"], &Map.delete(&1, Fixtures.id(:m_sonnet4)))

      {:ok, data, _} = SnapshotData.decode(snapshot)

      assert {:ok, r} = Resolver.resolve(data, "diary_generation")
      assert r.model == nil
      assert r.model_id == nil
      assert r.warnings == [{:missing_model, Fixtures.id(:m_sonnet4)}]
      # UseCase defaults are kept even when the model is missing
      assert r.effective_params == %{"temperature" => 0.4}
    end
  end

  describe "passthrough fields" do
    test "source and etag ride along", %{snapshot: snapshot} do
      assert {:ok, r} =
               Resolver.resolve(snapshot, "diary_generation", source: :bundle, etag: "W/\"abc\"")

      assert r.source == :bundle
      assert r.etag == "W/\"abc\""
    end

    test "source defaults to :remote and payload policy comes from the use case", %{
      snapshot: snapshot
    } do
      assert {:ok, r} = Resolver.resolve(snapshot, "diary_generation")
      assert r.source == :remote
      assert r.payload_policy.mode == :full

      assert r.input_schema |> Enum.map(& &1.name) |> Enum.sort() ==
               ~w(existing_diary mode transcriptions user_content)
    end
  end
end
