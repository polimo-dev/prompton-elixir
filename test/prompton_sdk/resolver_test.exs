defmodule PromptOnSDK.ResolverTest do
  @moduledoc """
  Prompt selection algorithm (snapshot v4): a deployment is a pin, not a router.
  With no rules, conditions, targets, or weights, only three things need verifying: (1) template name
  selection, (2) parameter merging, (3) the error/warning contract for what is missing (prompt,
  deployment, prompt, model).
  """

  use ExUnit.Case, async: true

  alias PromptOnSDK.{Fixtures, Prompt, PromptDocument, Resolver}

  setup do
    %{snapshot: Fixtures.snapshot_data()}
  end

  defp readable_snapshot do
    %{
      "schema_version" => 1,
      "project" => "helpdesk",
      "environment" => "production",
      "prompts" => %{
        "support_reply" => %{"kind" => "chat", "default_params" => %{"max_tokens" => 512}},
        "summary" => %{"kind" => "text", "default_params" => %{}}
      },
      "deployments" => %{
        "support_reply" => %{
          "revision" => "v2026.09.30-3",
          "provider" => "openrouter",
          "model" => "openai/gpt-4o-mini",
          "prompt_version" => 2,
          "params" => %{"temperature" => 0.3},
          "provider_options" => %{"allow_fallbacks" => false}
        },
        "summary" => %{
          "revision" => "v2026.09.30-4",
          "provider" => "openrouter",
          "model" => "openai/gpt-4o-mini",
          "prompt_version" => 2
        }
      },
      "prompt_versions" => %{
        "support_reply@2" => %{
          "prompt" => "support_reply",
          "number" => 2,
          "kind" => "chat",
          "engine" => "liquid",
          "messages" => [%{"role" => "user", "content" => "{{ question }}"}]
        },
        "summary@2" => %{
          "prompt" => "summary",
          "number" => 2,
          "kind" => "text",
          "engine" => "liquid",
          "text_template" => "Summary: {{ text }}"
        }
      },
      "models" => %{
        "openrouter:openai/gpt-4o-mini" => %{
          "provider" => "openrouter",
          "model" => "openai/gpt-4o-mini",
          "provider_options" => %{"only" => ["OpenAI"]}
        }
      }
    }
  end

  describe "prompt selection" do
    test "no :template resolves the \"default\" pin", %{snapshot: snapshot} do
      assert {:ok, r} = Resolver.resolve(snapshot, "diary_generation")

      assert r.template == "default"
      assert r.prompt_version_id == nil
      assert r.prompt_version_number == 2
      assert r.deployment_id == nil
      assert r.deployment_revision == "v2026.09.30-4"

      assert [%{role: "system", content: "You write diaries from voice transcriptions."} | _] =
               r.messages
    end

    test "a name the deployment does not pin is an error, never a silent default", %{
      snapshot: snapshot
    } do
      assert {:error, :unknown_template} =
               Resolver.resolve(snapshot, "diary_generation", template: "ja")

      assert {:error, :unknown_template} =
               Resolver.resolve(snapshot, "chat_response", template: "ko")
    end

    test "template_names/2 lists the pinned names", %{snapshot: snapshot} do
      assert {:ok, ["default"]} = Resolver.template_names(snapshot, "diary_generation")
      assert {:ok, ["default"]} = Resolver.template_names(snapshot, "chat_response")
      assert {:ok, []} = Resolver.template_names(snapshot, "diary_embedding")
      assert {:ok, []} = Resolver.template_names(snapshot, "transcript_revision")
      assert {:error, :unknown_prompt} = Resolver.template_names(snapshot, "nope")
    end
  end

  describe "schema v1 readable resources" do
    test "resolves readable model and prompt-version keys with nil legacy ids" do
      assert {:ok, snapshot, []} = PromptDocument.decode(readable_snapshot())
      assert {:ok, r} = Resolver.resolve(snapshot, "support_reply", source: :bundle)

      assert r.model == "openai/gpt-4o-mini"
      assert r.provider == :openrouter
      assert r.deployment_id == nil
      assert r.model_id == nil
      assert r.prompt_version_id == nil
      assert r.prompt_version_number == 2
      assert r.params == %{"max_tokens" => 512, "temperature" => 0.3}
      assert r.provider_options == %{"only" => ["OpenAI"], "allow_fallbacks" => false}

      prompt = Prompt.from_resolution(r)
      assert prompt.prompt_version == %{id: nil, number: 2}
      assert Prompt.to_resolution(prompt).prompt_version_number == 2
    end

    test "same version numbers are scoped by prompt key" do
      assert {:ok, snapshot, []} = PromptDocument.decode(readable_snapshot())
      assert {:ok, r} = Resolver.resolve(snapshot, "summary")

      assert r.prompt_version_number == 2
      assert r.text_template == "Summary: {{ text }}"
      assert r.prompt_version_id == nil
    end

    test "missing readable refs are rejected before they can resolve" do
      map =
        readable_snapshot()
        |> put_in(["prompts", "missing_refs"], %{"kind" => "chat", "default_params" => %{}})
        |> put_in(["deployments", "missing_refs"], %{
          "revision" => "v2026.09.30-5",
          "provider" => "openrouter",
          "model" => "openai/missing",
          "prompt_version" => 3
        })

      assert {:error, {:invalid_prompt_document, message}} = PromptDocument.decode(map)
      assert message =~ "deployment missing_refs references missing prompt version missing_refs@3"
    end
  end

  describe "kinds" do
    test "text prompt carries text_template and no messages", %{snapshot: snapshot} do
      assert {:ok, r} = Resolver.resolve(snapshot, "voice_transcription")

      assert r.kind == :text
      assert r.text_template == "Hello. Today's diary {{ verbatim }}"
      assert r.messages == nil
      assert r.engine == :raw
    end

    test "embedding prompt without a deployment is unresolved", %{snapshot: snapshot} do
      assert {:error, :unresolved} = Resolver.resolve(snapshot, "diary_embedding", template: "ko")
    end
  end

  describe "effective params" do
    test "deployment params/provider_options override prompt and model defaults", %{
      snapshot: snapshot
    } do
      assert {:ok, r} = Resolver.resolve(snapshot, "diary_generation")

      # prompt default_params temperature 0.5 ⊕ deployment 0.4
      assert r.params == %{"temperature" => 0.4}
      # model provider_options only:[Anthropic] ⊕ deployment allow_fallbacks:false
      assert r.provider_options == %{
               "only" => ["Anthropic"],
               "allow_fallbacks" => false
             }

      assert r.model == "anthropic/claude-sonnet-4"
      assert r.model_id == nil
      assert r.provider == :openrouter
    end

    test "prompt defaults survive when the deployment adds a different key", %{
      snapshot: snapshot
    } do
      assert {:ok, r} = Resolver.resolve(snapshot, "chat_response")
      assert r.params == %{"temperature" => 0.7, "max_tokens" => 1024}
    end
  end

  describe "errors and warnings" do
    test "unknown prompt", %{snapshot: snapshot} do
      assert {:error, :unknown_prompt} = Resolver.resolve(snapshot, "nope")
    end

    test "a prompt with no deployment is unresolved", %{snapshot: snapshot} do
      assert {:error, :unresolved} = Resolver.resolve(snapshot, "transcript_revision")
    end

    test "a deployment pointing at a missing prompt version is rejected at decode" do
      snapshot =
        Fixtures.snapshot()
        |> update_in(["prompt_versions"], &Map.delete(&1, "diary_generation@2"))

      assert {:error, {:invalid_prompt_document, message}} = PromptDocument.decode(snapshot)

      assert message =~
               "deployment diary_generation references missing prompt version diary_generation@2"
    end

    test "a deployment pointing at a missing model is rejected at decode" do
      snapshot =
        Fixtures.snapshot()
        |> update_in(["models"], &Map.delete(&1, "openrouter:anthropic/claude-sonnet-4"))

      assert {:error, {:invalid_prompt_document, message}} = PromptDocument.decode(snapshot)

      assert message =~
               "deployment diary_generation references missing model openrouter:anthropic/claude-sonnet-4"
    end
  end

  describe "passthrough fields" do
    test "source and etag ride along", %{snapshot: snapshot} do
      assert {:ok, r} =
               Resolver.resolve(snapshot, "diary_generation", source: :bundle, etag: "W/\"abc\"")

      assert r.source == :bundle
      assert r.etag == "W/\"abc\""
    end

    test "source defaults to :remote and payload policy comes from the prompt", %{
      snapshot: snapshot
    } do
      assert {:ok, r} = Resolver.resolve(snapshot, "diary_generation")
      assert r.source == :remote
      assert r.payload_policy.mode == :full

      assert r.variables |> Enum.map(& &1.name) |> Enum.sort() ==
               ~w(existing_diary mode transcriptions user_content)
    end
  end
end
