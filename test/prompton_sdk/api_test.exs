defmodule PromptOnSDK.APITest do
  use PromptOnSDK.RuntimeCase, async: false

  import PromptOnSDK.Test, only: [assert_logged: 1, assert_logged: 2, assert_feedback: 1]

  alias PromptOnSDK.{Generic, OpenRouter, Resolution}

  @gen_start [:prompton, :generation, :start]
  @gen_stop [:prompton, :generation, :stop]
  @gen_exception [:prompton, :generation, :exception]
  @resolve_stop [:prompton, :resolve, :stop]

  # Test mode without a supervisor: only the app env is set (same conditions as HeyDiary's tests)
  setup do
    Application.put_env(:prompton_sdk, :mode, :test)
    PromptOnSDK.Test.put_snapshot(Fixtures.snapshot())
    on_exit(&PromptOnSDK.Test.clear/0)
    :ok
  end

  describe "resolve wrappers" do
    test "resolve sets source/etag from the store and emits telemetry" do
      attach_telemetry([@resolve_stop])

      assert {:ok, %Resolution{} = r} = PromptOnSDK.resolve(:diary_generation, prompt: "ko")

      assert r.source == :manual
      assert r.etag == "test"
      assert r.prompt == "ko"
      assert r.prompt_version_id == Fixtures.id(:pv_ko)

      assert_receive {:telemetry, @resolve_stop, %{duration: _},
                      %{
                        use_case: "diary_generation",
                        source: :manual,
                        prompt: "ko",
                        result: :ok
                      }}
    end

    test "resolve errors pass through" do
      assert PromptOnSDK.resolve("nope") == {:error, :unknown_use_case}
      assert PromptOnSDK.resolve("transcript_revision") == {:error, :unresolved}
      assert PromptOnSDK.resolve("diary_generation", prompt: "ja") == {:error, :unknown_prompt}

      PromptOnSDK.Test.clear()
      assert PromptOnSDK.resolve("diary_generation") == {:error, :not_ready}
    end

    test "prompt_names/1 lists what the live deployment pins" do
      assert PromptOnSDK.prompt_names("diary_generation") == {:ok, ["default", "ko"]}
      assert PromptOnSDK.prompt_names("nope") == {:error, :unknown_use_case}

      PromptOnSDK.Test.clear()
      assert PromptOnSDK.prompt_names("diary_generation") == {:error, :not_ready}
    end
  end

  describe "render/2" do
    test "chat renders messages, text renders string, embedding has no template" do
      {:ok, r} = PromptOnSDK.resolve("diary_generation")

      assert {:ok,
              [
                %{role: "system", content: "You write diaries from voice transcriptions."},
                %{role: "user", content: user}
              ]} =
               PromptOnSDK.render(r, %{transcriptions: ["a", "b"], mode: "fresh"})

      assert user =~ "1. a\n\n2. b\n\n"

      assert {:error, {:missing_variable, "transcriptions"}} =
               PromptOnSDK.render(r, %{mode: "fresh"})

      assert_raise PromptOnSDK.RenderError, fn -> PromptOnSDK.render!(r, %{}) end

      {:ok, stt} = PromptOnSDK.resolve("voice_transcription")
      assert PromptOnSDK.render(stt, %{}) == {:ok, "Hello. Today's diary {{ verbatim }}"}
      assert PromptOnSDK.render!(stt, nil) =~ "verbatim"

      {:ok, emb} = PromptOnSDK.resolve("diary_embedding")
      assert PromptOnSDK.render(emb, %{}) == {:error, :no_template}
    end
  end

  describe "with_generation/3 (test mode → caller mailbox)" do
    setup do
      {:ok, r} = PromptOnSDK.resolve("diary_generation", prompt: "ko")
      %{r: r}
    end

    @or_resp %{
      "model" => "anthropic/claude-sonnet-4",
      "provider" => "Anthropic",
      "choices" => [%{"finish_reason" => "stop", "message" => %{"content" => "diary text"}}],
      "usage" => %{
        "prompt_tokens" => 100,
        "completion_tokens" => 20,
        "cost" => 0.002,
        "is_byok" => false
      }
    }

    test "{:ok, outcome} → status ok with usage/output, returns fun value", %{r: r} do
      attach_telemetry([@gen_start, @gen_stop])
      msgs = [%{"role" => "user", "content" => "hi"}]

      result =
        PromptOnSDK.with_generation(
          r,
          %{
            id: "gen-fixed",
            end_user_ref: "u1",
            trace_id: "oban:1",
            sequence: 1,
            input_messages: msgs,
            variables: %{transcriptions: ["a"]},
            context: %{language: "ko", plan: "pro"},
            metadata: %{job_id: 1},
            params: %{"max_tokens" => 999}
          },
          fn ->
            Process.sleep(5)
            {:ok, %{OpenRouter.outcome(@or_resp) | result: :parsed}}
          end
        )

      assert result == {:ok, %{OpenRouter.outcome(@or_resp) | result: :parsed}}
      gen = assert_logged(%{"id" => "gen-fixed"})

      assert gen["use_case"] == "diary_generation"
      assert gen["deployment_id"] == Fixtures.id(:d_diary)
      assert gen["deployment_revision"] == 4
      assert gen["prompt"] == "ko"
      assert gen["prompt_version_id"] == Fixtures.id(:pv_ko)
      refute Map.has_key?(gen, "target_id")
      refute Map.has_key?(gen, "rule_id")
      refute Map.has_key?(gen, "variant_id")
      assert gen["resolution_source"] == "manual"
      assert gen["context"] == %{"language" => "ko", "plan" => "pro"}
      assert gen["kind"] == "chat"
      assert gen["model"] == "anthropic/claude-sonnet-4"
      assert gen["model_used"] == "anthropic/claude-sonnet-4"
      assert gen["provider"] == "openrouter"
      assert gen["upstream_provider"] == "Anthropic"
      assert gen["params"] == %{"temperature" => 0.4, "max_tokens" => 999}
      assert gen["input"] == %{"variables" => %{"transcriptions" => ["a"]}, "messages" => msgs}
      assert gen["output"] == %{"content" => "diary text"}
      assert gen["status"] == "ok"
      assert gen["finish_reason"] == "stop"
      assert gen["stop_kind"] == "stop"
      refute Map.has_key?(gen, "error")
      assert gen["usage"]["input_tokens"] == 100
      assert gen["usage"]["output_tokens"] == 20
      assert gen["usage"]["cost_usd"] == 0.002
      assert gen["usage"]["cost_source"] == "provider"
      assert gen["usage"]["raw"] == @or_resp["usage"]
      assert gen["latency_ms"] >= 5
      assert {:ok, _, 0} = DateTime.from_iso8601(gen["started_at"])
      assert gen["trace_id"] == "oban:1"
      assert gen["sequence"] == 1
      assert gen["end_user_ref"] == "u1"
      assert gen["metadata"] == %{"job_id" => 1, "is_byok" => false}
      assert gen["sdk"] == %{"name" => "prompton_sdk", "version" => PromptOnSDK.version()}

      assert_receive {:telemetry, @gen_start, %{system_time: _},
                      %{id: "gen-fixed", use_case: "diary_generation"}}

      assert_receive {:telemetry, @gen_stop,
                      %{input_tokens: 100, output_tokens: 20, cost_usd: 0.002},
                      %{status: :ok, stop_kind: "stop"}}
    end

    test "{:error, error} → status error, error kind normalized", %{r: r} do
      result =
        PromptOnSDK.with_generation(r, %{}, fn ->
          {:error, %{kind: :http_5xx, status: 502, message: "bad gateway"}}
        end)

      assert result == {:error, %{kind: :http_5xx, status: 502, message: "bad gateway"}}
      gen = assert_logged(%{"status" => "error"})
      assert gen["error"] == %{"kind" => "http_5xx", "status" => 502, "message" => "bad gateway"}
      refute Map.has_key?(gen, "output")
      assert gen["usage"]["cost_source"] == "unknown"
      assert gen["id"] =~ ~r/^[0-9a-f-]{36}$/

      PromptOnSDK.with_generation(r, %{}, fn ->
        {:error, %{"kind" => "weird", "message" => %{a: 1}}}
      end)

      gen = assert_logged(%{"status" => "error"})
      assert gen["error"]["kind"] == "app"
      assert gen["error"]["message"] =~ "a: 1"
    end

    test "OpenRouter tool_calls outcome keeps stop_kind tool_call end-to-end", %{r: r} do
      resp =
        @or_resp
        |> put_in(["choices", Access.at(0), "finish_reason"], "tool_calls")
        |> put_in(["choices", Access.at(0), "message"], %{
          "content" => nil,
          "tool_calls" => [%{"id" => "c1", "function" => %{"name" => "f", "arguments" => "{}"}}]
        })

      outcome = OpenRouter.outcome(resp)
      assert outcome.stop_kind == :tool_call

      PromptOnSDK.with_generation(r, %{id: "gen-tool"}, fn -> {:ok, outcome} end)

      gen = assert_logged(%{"id" => "gen-tool"})
      assert gen["finish_reason"] == "tool_calls"
      assert gen["stop_kind"] == "tool_call"
      assert [%{"id" => "c1"}] = gen["output"]["tool_calls"]

      # A string-keyed outcome (stop_kind already normalized) passes through as-is too
      PromptOnSDK.with_generation(r, %{id: "gen-tool-2"}, fn ->
        {:ok, %{"content" => "x", "stop_kind" => "tool_call", "finish_reason" => "tool_calls"}}
      end)

      assert assert_logged(%{"id" => "gen-tool-2"})["stop_kind"] == "tool_call"
    end

    test "{:error, error, outcome} keeps usage/output (parse failure as quality signal)", %{r: r} do
      outcome =
        OpenRouter.outcome(put_in(@or_resp, ["choices", Access.at(0), "finish_reason"], "length"))

      PromptOnSDK.with_generation(r, %{metadata: %{attempt: 3, final_attempt: true}}, fn ->
        {:error, %{kind: :app, message: "truncated after 3 attempts"}, outcome}
      end)

      gen = assert_logged(%{"status" => "error"})
      assert gen["error"] == %{"kind" => "app", "message" => "truncated after 3 attempts"}
      assert gen["output"] == %{"content" => "diary text"}
      assert gen["usage"]["input_tokens"] == 100
      assert gen["stop_kind"] == "length"
      assert gen["metadata"] == %{"attempt" => 3, "final_attempt" => true, "is_byok" => false}
    end

    test "exceptions are logged as error/app and re-raised; exits/throws too", %{r: r} do
      attach_telemetry([@gen_exception])

      assert_raise RuntimeError, "boom", fn ->
        PromptOnSDK.with_generation(r, %{trace_id: "t"}, fn -> raise "boom" end)
      end

      gen = assert_logged(%{"status" => "error", "trace_id" => "t"})
      assert gen["error"]["kind"] == "app"
      assert gen["error"]["message"] =~ "boom"

      assert_receive {:telemetry, @gen_exception, %{duration: _},
                      %{kind: :error, reason: %RuntimeError{}}}

      assert catch_throw(PromptOnSDK.with_generation(r, %{}, fn -> throw(:ball) end)) == :ball
      assert_logged(%{"status" => "error"})

      assert catch_exit(PromptOnSDK.with_generation(r, %{}, fn -> exit(:bye) end)) == :bye
      assert_logged(%{"status" => "error"})
    end

    test "non-tuple return is status ok without usage", %{r: r} do
      assert PromptOnSDK.with_generation(r, %{}, fn -> :whatever end) == :whatever
      gen = assert_logged(%{"status" => "ok"})
      refute Map.has_key?(gen, "output")
      refute Map.has_key?(gen, "stop_kind")
    end

    test "Generic outcome and string-key meta/outcome are accepted", %{r: r} do
      {:ok, stt} = PromptOnSDK.resolve("voice_transcription")

      PromptOnSDK.with_generation(stt, %{"trace_id" => "g", "end_user_ref" => 42}, fn ->
        {:ok,
         Generic.outcome(%{
           input_tokens: 10,
           output_tokens: 0,
           content: "text",
           finish_reason: "length"
         })}
      end)

      gen = assert_logged(%{"trace_id" => "g"})
      assert gen["kind"] == "text"
      assert gen["provider"] == "groq"
      assert gen["end_user_ref"] == "42"
      assert gen["usage"]["input_tokens"] == 10

      # The voice_transcription policy is :hash (sample 0.1, but truncated generations are always
      # kept), so a hash is stored instead of the raw text
      assert %{"sha256" => _, "bytes" => _} = gen["output"]

      PromptOnSDK.with_generation(r, %{}, fn ->
        {:ok, %{"content" => "c", "usage" => %{"input_tokens" => 1}}}
      end)

      gen = assert_logged(%{"status" => "ok"})
      assert gen["output"] == %{"content" => "c"}
      assert gen["usage"]["input_tokens"] == 1
    end

    test "payload policy from the resolution is applied (embedding = none)", %{r: _} do
      {:ok, emb} = PromptOnSDK.resolve("diary_embedding")

      PromptOnSDK.with_generation(
        emb,
        %{input_messages: [%{"role" => "user", "content" => "secret"}]},
        fn ->
          {:ok, %{content: "vec", usage: %{input_tokens: 5, output_tokens: 0}}}
        end
      )

      gen = assert_logged(%{"use_case" => "diary_embedding"})
      refute Map.has_key?(gen, "input")
      refute Map.has_key?(gen, "output")
      assert gen["usage"]["input_tokens"] == 5
    end
  end

  describe "log/1 and feedback/1" do
    test "log/1 fills id/started_at/sdk, applies snapshot policy by use_case, stringifies keys" do
      # The voice_transcription policy is :hash + sample_rate 0.1; errors are always kept, so a
      # hash remains
      assert :ok =
               PromptOnSDK.log(%{
                 use_case: "voice_transcription",
                 status: :error,
                 output: %{content: "x"},
                 model: "whisper"
               })

      gen = assert_logged(%{"use_case" => "voice_transcription"})
      assert gen["id"] =~ ~r/^[0-9a-f-]{36}$/
      assert {:ok, _, _} = DateTime.from_iso8601(gen["started_at"])
      assert gen["sdk"]["name"] == "prompton_sdk"
      assert %{"sha256" => _} = gen["output"]

      # Policy override
      assert :ok =
               PromptOnSDK.log(
                 %{"use_case" => "voice_transcription", "output" => %{"content" => "x"}},
                 policy: %{mode: :full}
               )

      gen = assert_logged(%{"use_case" => "voice_transcription"})
      assert gen["output"] == %{"content" => "x"}
    end

    test "log/1 never raises" do
      assert :ok =
               PromptOnSDK.log(%{
                 "use_case" => "x",
                 "input" => %{"messages" => [%{"content" => make_ref()}]}
               })

      assert :ok = PromptOnSDK.log(:not_a_map)
    end

    test "feedback/1 requires generation_id and kind, hashes end_user_ref when configured" do
      assert :ok =
               PromptOnSDK.feedback(%{
                 generation_id: "g1",
                 kind: "thumbs",
                 value: 1,
                 end_user_ref: "u"
               })

      fb = assert_feedback(%{"generation_id" => "g1"})
      assert fb["kind"] == "thumbs" and fb["end_user_ref"] == "u"
      assert {:ok, _, _} = DateTime.from_iso8601(fb["occurred_at"])

      assert :ok = PromptOnSDK.feedback(%{kind: "thumbs"})
      refute_receive {:prompton_feedback, _}, 10

      Application.put_env(:prompton_sdk, :hash_end_user, true)

      PromptOnSDK.feedback(%{
        generation_id: "g2",
        kind: "score",
        evaluator: "mood",
        value: 1.0,
        end_user_ref: "u"
      })

      fb = assert_feedback(%{"generation_id" => "g2"})
      assert fb["end_user_ref"] == PromptOnSDK.Payload.sha256_hex("u")
    end
  end

  describe "live mode without a buffer" do
    test "log/1 drops with a once-per-minute warning and dropped telemetry" do
      Application.put_env(:prompton_sdk, :mode, :live)
      attach_telemetry([[:prompton, :log, :dropped]])

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :ok = PromptOnSDK.log(%{"use_case" => "diary_generation"})
          assert :ok = PromptOnSDK.log(%{"use_case" => "diary_generation"})
        end)

      assert length(Regex.scan(~r/Buffer is not running/, log)) == 1
      assert_receive {:telemetry, [:prompton, :log, :dropped], %{count: 1}, %{reason: :no_buffer}}
      assert_receive {:telemetry, [:prompton, :log, :dropped], %{count: 1}, %{reason: :no_buffer}}
      refute_receive {:prompton_generation, _}, 10
    end
  end

  describe "live mode end-to-end through the buffer" do
    test "with_generation → Buffer → client.post_generations" do
      Application.delete_env(:prompton_sdk, :mode)
      FakeClient.notify(self())
      FakeClient.set(:fetch_snapshot, fn _, _ -> {:error, :offline} end)
      FakeClient.set(:post_generations, fn _ -> ok_202(1) end)
      bundle = tmp_path("bundle.json")
      write_snapshot_file(bundle, Fixtures.snapshot())
      start_sdk(bundle: {:file, bundle}, log: [flush_size: 1, flush_interval: 60_000])

      {:ok, r} = PromptOnSDK.resolve("diary_generation", %{language: "ko", plan: "pro"})
      PromptOnSDK.with_generation(r, %{id: "e2e"}, fn -> {:ok, OpenRouter.outcome(@or_resp)} end)

      assert_receive {:fake_client, :post_generations,
                      [[%{"id" => "e2e", "resolution_source" => "bundle"}]]},
                     500

      refute_receive {:prompton_generation, _}, 10
    end
  end

  describe "PromptOnSDK.Test.stub/2" do
    test "builds a minimal snapshot per use case and accumulates" do
      PromptOnSDK.Test.clear()

      PromptOnSDK.Test.stub("diary_generation", %{
        model: "openai/gpt-5-mini",
        messages: [%{role: "system", content: "sys"}, %{role: "user", content: "{{ text }}"}],
        params: %{temperature: 0.2}
      })

      PromptOnSDK.Test.stub(:voice_transcription,
        kind: :text,
        model: "whisper-large-v3",
        provider: :groq,
        text_template: "hint"
      )

      PromptOnSDK.Test.stub(:diary_embedding,
        kind: :embedding,
        model: "text-embedding-3-small",
        payload_policy: %{mode: "none"}
      )

      {:ok, r} = PromptOnSDK.resolve("diary_generation", %{anything: "goes"})
      assert r.model == "openai/gpt-5-mini"
      assert r.provider == :openrouter
      assert r.effective_params == %{"temperature" => 0.2}
      assert {:ok, [_, %{content: "hello"}]} = PromptOnSDK.render(r, %{text: "hello"})

      {:ok, stt} = PromptOnSDK.resolve("voice_transcription", %{})
      assert stt.provider == :groq and stt.kind == :text
      assert PromptOnSDK.render(stt, %{}) == {:ok, "hint"}

      {:ok, emb} = PromptOnSDK.resolve("diary_embedding", %{})
      assert emb.kind == :embedding and emb.payload_policy.mode == :none

      PromptOnSDK.with_generation(r, %{}, fn -> {:ok, %{content: "out"}} end)
      assert_logged(%{"use_case" => "diary_generation", "output" => %{"content" => "out"}}, 100)
      assert PromptOnSDK.Test.logged() == []
    end

    test "put_snapshot from file" do
      path = tmp_path("snap.json")
      File.write!(path, Jason.encode!(Fixtures.snapshot()))
      PromptOnSDK.Test.clear()
      PromptOnSDK.Test.put_snapshot({:file, path})
      assert {:ok, _} = PromptOnSDK.resolve("chat_response", %{})
      assert_raise ArgumentError, fn -> PromptOnSDK.Test.put_snapshot(%{"nope" => 1}) end
    end
  end
end
