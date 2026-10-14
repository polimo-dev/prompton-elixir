defmodule PromptOnSDK.APITest do
  use PromptOnSDK.RuntimeCase, async: false

  import PromptOnSDK.Test, only: [assert_logged: 1, assert_logged: 2, assert_feedback: 1]

  alias PromptOnSDK.{Prompt, Result}

  @gen_start [:prompton, :log, :start]
  @gen_stop [:prompton, :log, :stop]
  @gen_exception [:prompton, :log, :exception]
  @prompt_stop [:prompton, :prompt, :stop]

  # Test mode without a supervisor: only the app env is set (same conditions as HeyDiary's tests)
  setup do
    Application.put_env(:prompton_sdk, :mode, :test)
    PromptOnSDK.Test.put_prompt_document(Fixtures.snapshot())
    on_exit(&PromptOnSDK.Test.clear/0)
    :ok
  end

  describe "prompt wrappers" do
    test "prompt sets source/etag from the store and emits telemetry" do
      attach_telemetry([@prompt_stop])

      assert {:ok, %Prompt{} = r} = PromptOnSDK.prompt(:diary_generation)

      assert r.source == :manual
      assert r.etag == "test"
      assert r.template == "default"
      assert r.prompt_version.id == nil

      assert_receive {:telemetry, @prompt_stop, %{duration: _},
                      %{
                        prompt_key: "diary_generation",
                        source: :manual,
                        template: "default",
                        result: :ok
                      }}
    end

    test "request records prepared messages and tools for the next generation log" do
      PromptOnSDK.Test.stub("tool_chat", %{
        model: "openai/gpt-5-mini",
        api: :chat_completions,
        request_path: "/api/v1/chat/completions",
        messages: [%{role: "user", content: "{{ input }}"}],
        tools: %{
          definitions: [
            %{
              type: "function",
              function: %{name: "lookup", parameters: %{type: "object"}},
              output_schema: %{type: "object"}
            }
          ],
          tool_choice: "auto",
          parallel_tool_calls: false
        }
      })

      {:ok, prompt} = PromptOnSDK.prompt("tool_chat")
      assert {:ok, request} = PromptOnSDK.request(prompt, %{input: "hi"})

      assert {:ok, %{content: "ok"}} =
               PromptOnSDK.track(prompt, %{id: "tool-log"}, fn ->
                 {:ok, %{content: "ok"}}
               end)

      log = assert_logged(%{"id" => "tool-log"})
      assert log["input"]["messages"] == request.body["messages"]
      assert log["input"]["tools"] == request.body["tools"]
      assert log["input"]["tool_choice"] == "auto"
      assert log["input"]["parallel_tool_calls"] == false
      refute log["input"]["tools"] |> hd() |> Map.has_key?("output_schema")
    end

    test "apps can replace prepared messages with final conversation messages when tracking" do
      PromptOnSDK.Test.stub("conversation_chat", %{
        model: "openai/gpt-5-mini",
        api: :chat_completions,
        request_path: "/api/v1/chat/completions",
        messages: [%{role: "system", content: "Answer in {{ tone }} tone."}],
        params: %{temperature: 0.2}
      })

      history = [
        %{"role" => "user", "content" => "Earlier question"},
        %{"role" => "assistant", "content" => nil, "tool_calls" => [%{"id" => "call_1"}]},
        %{
          "role" => "tool",
          "tool_call_id" => "call_1",
          "content" => [%{"type" => "text", "text" => "result"}]
        }
      ]

      {:ok, prompt} = PromptOnSDK.prompt("conversation_chat")
      assert {:ok, request} = PromptOnSDK.request(prompt, %{tone: "direct"})

      final_messages =
        request.body["messages"] ++ history ++ [%{"role" => "user", "content" => "Now answer"}]

      provider_body = Map.put(request.body, "messages", final_messages)

      assert provider_body["temperature"] == 0.2
      assert provider_body["messages"] == final_messages

      assert {:ok, %{content: "ok"}} =
               PromptOnSDK.track(
                 prompt,
                 %{
                   id: "conversation-log",
                   input_messages: final_messages,
                   variables: %{tone: "direct"}
                 },
                 fn -> {:ok, %{content: "ok"}} end
               )

      log = assert_logged(%{"id" => "conversation-log"})
      assert log["input"]["messages"] == final_messages
      assert log["input"]["variables"] == %{"tone" => "direct"}
    end

    test "prompt errors pass through" do
      assert PromptOnSDK.prompt("nope") == {:error, :unknown_prompt}
      assert PromptOnSDK.prompt("transcript_revision") == {:error, :unresolved}
      assert PromptOnSDK.prompt("diary_generation", template: "ja") == {:error, :unknown_template}

      PromptOnSDK.Test.clear()
      assert PromptOnSDK.prompt("diary_generation") == {:error, :not_ready}
    end

    test "template_names/1 lists what the live deployment pins" do
      assert PromptOnSDK.template_names("diary_generation") == {:ok, ["default"]}
      assert PromptOnSDK.template_names("nope") == {:error, :unknown_prompt}

      PromptOnSDK.Test.clear()
      assert PromptOnSDK.template_names("diary_generation") == {:error, :not_ready}
    end
  end

  describe "rendering" do
    test "chat renders messages, text renders string, embedding has no template" do
      {:ok, r} = PromptOnSDK.prompt("diary_generation")

      assert {:ok,
              [
                %{role: "system", content: "You write diaries from voice transcriptions."},
                %{role: "user", content: user}
              ]} =
               PromptOnSDK.messages(r, %{transcriptions: ["a", "b"], mode: "fresh"})

      assert user =~ "1. a\n\n2. b\n\n"

      assert {:error, {:missing_variable, "transcriptions"}} =
               PromptOnSDK.messages(r, %{mode: "fresh"})

      assert {:error, {:missing_variable, "transcriptions"}} = PromptOnSDK.messages(r, %{})

      {:ok, stt} = PromptOnSDK.prompt("voice_transcription")
      assert PromptOnSDK.text(stt, %{}) == {:ok, "Hello. Today's diary {{ verbatim }}"}

      assert PromptOnSDK.prompt("diary_embedding") == {:error, :unresolved}
    end

    test "messages/3 and text/3 accept only deployed template pins" do
      {:ok, r} = PromptOnSDK.prompt("diary_generation")

      assert r.template == "default"

      assert {:ok, [%{role: "system"}, %{role: "user", content: user}]} =
               PromptOnSDK.messages(r, %{transcriptions: ["안녕"], mode: "fresh"},
                 template: "default"
               )

      assert user =~ "1. 안녕"

      assert {:error, :unknown_template} =
               PromptOnSDK.messages(r, %{transcriptions: ["x"], mode: "fresh"}, template: "ja")

      {:ok, stt} = PromptOnSDK.prompt("voice_transcription")

      assert PromptOnSDK.text(stt, %{}, template: "default") ==
               {:ok, "Hello. Today's diary {{ verbatim }}"}

      assert PromptOnSDK.text(stt, %{}, template: "ignored") == {:error, :unknown_template}
    end
  end

  describe "track/3 (test mode → caller mailbox)" do
    setup do
      {:ok, r} = PromptOnSDK.prompt("diary_generation")
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

    test "{:ok, result} → status ok with usage/output, returns fun value", %{r: r} do
      attach_telemetry([@gen_start, @gen_stop])
      msgs = [%{"role" => "user", "content" => "hi"}]

      result =
        PromptOnSDK.track(
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
            {:ok, %{Result.from_openai(@or_resp) | result: :parsed}}
          end
        )

      assert result == {:ok, %{Result.from_openai(@or_resp) | result: :parsed}}
      gen = assert_logged(%{"id" => "gen-fixed"})

      assert gen["prompt_key"] == "diary_generation"
      refute Map.has_key?(gen, "deployment_id")
      refute Map.has_key?(gen, "model_id")
      assert gen["deployment_revision"] == "v2026.09.30-4"
      assert gen["template"] == "default"
      refute Map.has_key?(gen, "prompt_version_id")
      assert gen["prompt_version_number"] == 2
      refute Map.has_key?(gen, "target_id")
      refute Map.has_key?(gen, "rule_id")
      refute Map.has_key?(gen, "variant_id")
      assert gen["source"] == "manual"
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
                      %{id: "gen-fixed", prompt_key: "diary_generation"}}

      assert_receive {:telemetry, @gen_stop,
                      %{input_tokens: 100, output_tokens: 20, cost_usd: 0.002},
                      %{status: :ok, stop_kind: "stop"}}
    end

    test "manual logs strip retired resource reference fields" do
      assert :ok =
               PromptOnSDK.log(%{
                 "id" => "manual-readable-refs",
                 "prompt_key" => "diary_generation",
                 "model" => "anthropic/claude-sonnet-4",
                 "status" => "ok",
                 "deployment_id" => Fixtures.id(:d_diary),
                 "deployment_revision" => "v2026.09.30-4",
                 "prompt_version_id" => nil,
                 "prompt_version_number" => 2,
                 "model_id" => Fixtures.id(:m_sonnet4)
               })

      gen = assert_logged(%{"id" => "manual-readable-refs"})
      refute Map.has_key?(gen, "deployment_id")
      refute Map.has_key?(gen, "prompt_version_id")
      refute Map.has_key?(gen, "model_id")
      assert gen["deployment_revision"] == "v2026.09.30-4"
      assert gen["prompt_version_number"] == 2
    end

    test "track/3 can derive the same named template as messages/3 from template meta" do
      {:ok, default_template} = PromptOnSDK.prompt("diary_generation")

      assert {:ok, [%{content: "You write diaries from voice transcriptions."}, _]} =
               PromptOnSDK.messages(default_template, %{transcriptions: ["a"], mode: "fresh"})

      assert {:ok, _result} =
               PromptOnSDK.track(
                 default_template,
                 %{id: "default-derived", template: "default"},
                 fn ->
                   {:ok, Result.from_openai(@or_resp)}
                 end
               )

      gen = assert_logged(%{"id" => "default-derived"})
      assert gen["template"] == "default"
      assert gen["prompt_version_number"] == 2
      refute Map.has_key?(gen, "prompt_version_id")

      refute get_in(gen, ["metadata", "template"])

      assert {:error, :unknown_template} =
               PromptOnSDK.track(default_template, %{template: "ja"}, fn -> :not_called end)
    end

    test "track/3 consumes the template selected by messages/3 and does not leak it", %{r: r} do
      {:ok, default_template} = PromptOnSDK.prompt("diary_generation")

      assert {:ok, msgs} =
               PromptOnSDK.messages(default_template, %{transcriptions: ["a"], mode: "fresh"})

      assert {:ok, _result} =
               PromptOnSDK.track(
                 default_template,
                 %{id: "default-auto", input_messages: msgs},
                 fn -> {:ok, Result.from_openai(@or_resp)} end
               )

      gen = assert_logged(%{"id" => "default-auto"})
      assert gen["template"] == "default"
      assert gen["prompt_version_number"] == 2
      refute Map.has_key?(gen, "prompt_version_id")

      assert {:ok, _result} =
               PromptOnSDK.track(r, %{id: "default-after-render"}, fn ->
                 {:ok, Result.from_openai(@or_resp)}
               end)

      gen = assert_logged(%{"id" => "default-after-render"})
      assert gen["template"] == "default"
      assert gen["prompt_version_number"] == 2
      refute Map.has_key?(gen, "prompt_version_id")

      assert {:ok, _result} =
               PromptOnSDK.track(default_template, %{id: "default-after-consume"}, fn ->
                 {:ok, Result.from_openai(@or_resp)}
               end)

      gen = assert_logged(%{"id" => "default-after-consume"})
      assert gen["template"] == "default"
      assert gen["prompt_version_number"] == 2
      refute Map.has_key?(gen, "prompt_version_id")
    end

    test "{:error, error} → status error, error kind normalized", %{r: r} do
      result =
        PromptOnSDK.track(r, %{}, fn ->
          {:error, %{kind: :http_5xx, status: 502, message: "bad gateway"}}
        end)

      assert result == {:error, %{kind: :http_5xx, status: 502, message: "bad gateway"}}
      gen = assert_logged(%{"status" => "error"})
      assert gen["error"] == %{"kind" => "http_5xx", "status" => 502, "message" => "bad gateway"}
      refute Map.has_key?(gen, "output")
      assert gen["usage"]["cost_source"] == "unknown"
      assert gen["id"] =~ ~r/^[0-9a-f-]{36}$/

      PromptOnSDK.track(r, %{}, fn ->
        {:error, %{"kind" => "weird", "message" => %{a: 1}}}
      end)

      gen = assert_logged(%{"status" => "error"})
      assert gen["error"]["kind"] == "app"
      assert gen["error"]["message"] =~ "a: 1"
    end

    test "Result.from_openai tool_calls result keeps stop_kind tool_call end-to-end", %{r: r} do
      resp =
        @or_resp
        |> put_in(["choices", Access.at(0), "finish_reason"], "tool_calls")
        |> put_in(["choices", Access.at(0), "message"], %{
          "content" => nil,
          "tool_calls" => [%{"id" => "c1", "function" => %{"name" => "f", "arguments" => "{}"}}]
        })

      provider_result = Result.from_openai(resp)
      assert provider_result.stop_kind == :tool_call

      PromptOnSDK.track(r, %{id: "gen-tool"}, fn -> {:ok, provider_result} end)

      gen = assert_logged(%{"id" => "gen-tool"})
      assert gen["finish_reason"] == "tool_calls"
      assert gen["stop_kind"] == "tool_call"
      assert [%{"id" => "c1"}] = gen["output"]["tool_calls"]

      # A string-keyed result map (stop_kind already normalized) passes through as-is too.
      PromptOnSDK.track(r, %{id: "gen-tool-2"}, fn ->
        {:ok, %{"content" => "x", "stop_kind" => "tool_call", "finish_reason" => "tool_calls"}}
      end)

      assert assert_logged(%{"id" => "gen-tool-2"})["stop_kind"] == "tool_call"
    end

    test "{:error, error, result} keeps usage/output (parse failure as quality signal)", %{r: r} do
      provider_result =
        Result.from_openai(put_in(@or_resp, ["choices", Access.at(0), "finish_reason"], "length"))

      PromptOnSDK.track(r, %{metadata: %{attempt: 3, final_attempt: true}}, fn ->
        {:error, %{kind: :app, message: "truncated after 3 attempts"}, provider_result}
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
        PromptOnSDK.track(r, %{trace_id: "t"}, fn -> raise "boom" end)
      end

      gen = assert_logged(%{"status" => "error", "trace_id" => "t"})
      assert gen["error"]["kind"] == "app"
      assert gen["error"]["message"] =~ "boom"

      assert_receive {:telemetry, @gen_exception, %{duration: _},
                      %{kind: :error, reason: %RuntimeError{}}}

      assert catch_throw(PromptOnSDK.track(r, %{}, fn -> throw(:ball) end)) == :ball
      assert_logged(%{"status" => "error"})

      assert catch_exit(PromptOnSDK.track(r, %{}, fn -> exit(:bye) end)) == :bye
      assert_logged(%{"status" => "error"})
    end

    test "non-tuple return is status ok without usage", %{r: r} do
      assert PromptOnSDK.track(r, %{}, fn -> :whatever end) == :whatever
      gen = assert_logged(%{"status" => "ok"})
      refute Map.has_key?(gen, "output")
      refute Map.has_key?(gen, "stop_kind")
    end

    test "Result.from_generic and string-key meta/result maps are accepted", %{r: r} do
      {:ok, stt} = PromptOnSDK.prompt("voice_transcription")

      PromptOnSDK.track(stt, %{"trace_id" => "g", "end_user_ref" => 42}, fn ->
        {:ok,
         Result.from_generic(%{
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

      # The voice_transcription policy is :hash (sample 0.1, but truncated logs are always
      # kept), so a hash is stored instead of the raw text
      assert %{"sha256" => _, "bytes" => _} = gen["output"]

      PromptOnSDK.track(r, %{}, fn ->
        {:ok, %{"content" => "c", "usage" => %{"input_tokens" => 1}}}
      end)

      gen = assert_logged(%{"status" => "ok"})
      assert gen["output"] == %{"content" => "c"}
      assert gen["usage"]["input_tokens"] == 1
    end

    test "payload policy from an unresolved embedding prompt is not applied", %{r: _} do
      assert PromptOnSDK.prompt("diary_embedding") == {:error, :unresolved}
    end
  end

  describe "log/1 and feedback/1" do
    test "log/1 fills id/started_at/sdk, applies prompt policy by key, stringifies keys" do
      # The voice_transcription policy is :hash + sample_rate 0.1; errors are always kept, so a
      # hash remains
      assert :ok =
               PromptOnSDK.log(%{
                 prompt_key: "voice_transcription",
                 status: :error,
                 output: %{content: "x"},
                 model: "whisper"
               })

      gen = assert_logged(%{"prompt_key" => "voice_transcription"})
      assert gen["id"] =~ ~r/^[0-9a-f-]{36}$/
      assert {:ok, _, _} = DateTime.from_iso8601(gen["started_at"])
      assert gen["sdk"]["name"] == "prompton_sdk"
      assert %{"sha256" => _} = gen["output"]

      # Policy override
      assert :ok =
               PromptOnSDK.log(
                 %{"prompt_key" => "voice_transcription", "output" => %{"content" => "x"}},
                 policy: %{mode: :full}
               )

      gen = assert_logged(%{"prompt_key" => "voice_transcription"})
      assert gen["output"] == %{"content" => "x"}
    end

    test "log/1 never raises" do
      assert :ok =
               PromptOnSDK.log(%{
                 "prompt_key" => "x",
                 "input" => %{"messages" => [%{"content" => make_ref()}]}
               })

      assert :ok = PromptOnSDK.log(:not_a_map)
    end

    test "feedback/1 requires log_id and kind, hashes end_user_ref when configured" do
      assert :ok =
               PromptOnSDK.feedback(%{
                 log_id: "g1",
                 kind: "thumbs",
                 value: 1,
                 end_user_ref: "u"
               })

      fb = assert_feedback(%{"log_id" => "g1"})
      assert fb["kind"] == "thumbs" and fb["end_user_ref"] == "u"
      assert {:ok, _, _} = DateTime.from_iso8601(fb["occurred_at"])

      assert :ok = PromptOnSDK.feedback(%{kind: "thumbs"})
      refute_receive {:prompton_feedback, _}, 10

      Application.put_env(:prompton_sdk, :hash_end_user, true)

      PromptOnSDK.feedback(%{
        log_id: "g2",
        kind: "score",
        evaluator: "mood",
        value: 1.0,
        end_user_ref: "u"
      })

      fb = assert_feedback(%{"log_id" => "g2"})
      assert fb["end_user_ref"] == PromptOnSDK.Payload.sha256_hex("u")
    end
  end

  describe "live mode without a buffer" do
    test "log_events/2 normalizes trace events and sends them in test mode" do
      observed_at = DateTime.utc_now()

      assert :ok =
               PromptOnSDK.log_events(%{
                 trace_id: "trace-1",
                 event_kind: :tool_attempt,
                 status: :ok,
                 observed_at: observed_at,
                 tool_call_id: "call_1",
                 tool_name: "search_diary",
                 result: %{content: [%{type: "text", text: "found"}]}
               })

      assert_receive {:prompton_events, [event]}
      assert event["trace_id"] == "trace-1"
      assert event["event_kind"] == "tool_attempt"
      assert event["status"] == "ok"
      assert is_binary(event["event_id"])
      assert event["observed_at"] == DateTime.to_iso8601(observed_at)
      assert event["result"] == %{"content" => [%{"type" => "text", "text" => "found"}]}
      assert event["sdk"] == %{"name" => "prompton_sdk", "version" => PromptOnSDK.version()}
    end

    test "log_events/2 validates required fields and allowed enums" do
      assert {:error, {:invalid_event, 1, :trace_id_required}} =
               PromptOnSDK.log_events(%{event_kind: "tool_attempt", status: "ok"})

      assert {:error, {:invalid_event, 1, :invalid_event_kind}} =
               PromptOnSDK.log_events(%{trace_id: "trace-1", event_kind: "unknown", status: "ok"})

      assert {:error, {:too_many_events, 501}} =
               PromptOnSDK.log_events(
                 for i <- 1..501 do
                   %{trace_id: "trace-#{i}", event_kind: "completion", status: "ok"}
                 end
               )
    end

    test "log_events/2 sync in test mode uses the real nested events ack shape" do
      assert {:ok, %{status: 202, body: body}} =
               PromptOnSDK.log_events(
                 %{trace_id: "trace-test", event_kind: "completion", status: "ok"},
                 sync: true
               )

      assert body["accepted"] == 0
      assert body["duplicates"] == 0
      assert body["rejected"] == []
      assert body["events"] == %{"accepted" => 1, "duplicates" => 0, "rejected" => []}
      assert_receive {:prompton_events, [%{"trace_id" => "trace-test"}]}
    end

    test "log_events/2 sync posts events and preserves nested rejected evidence" do
      Application.put_env(:prompton_sdk, :mode, :live)
      Application.put_env(:prompton_sdk, :base_url, "http://prompton.test/api/v1")
      Application.put_env(:prompton_sdk, :client, FakeClient)
      FakeClient.notify(self())

      FakeClient.set(:post_events, fn events ->
        assert [%{"event_id" => "evt-1", "trace_id" => "trace-1"}] = events

        {:ok,
         %{
           status: 202,
           body: %{
             "accepted" => 0,
             "duplicates" => 0,
             "rejected" => [],
             "events" => %{
               "accepted" => 0,
               "duplicates" => 0,
               "rejected" => [%{"event_id" => "evt-1", "reason" => "bad evidence"}]
             }
           },
           headers: %{}
         }}
      end)

      assert {:ok, %{status: 202, body: body}} =
               PromptOnSDK.log_events(
                 %{
                   event_id: "evt-1",
                   trace_id: "trace-1",
                   event_kind: "completion",
                   status: "incomplete"
                 },
                 sync: true,
                 timeout: 1234
               )

      assert body["rejected"] == []

      assert body["events"]["rejected"] == [
               %{"event_id" => "evt-1", "reason" => "bad evidence"}
             ]

      assert_receive {:fake_client, :post_events, [[%{"event_id" => "evt-1"} = event]]}
      assert event["observed_at"]
    end

    test "log final scrub removes retired refs added by redaction before capture" do
      Application.put_env(:prompton_sdk, :log,
        redact: fn log ->
          log
          |> Map.put("deployment_id", Fixtures.id(:d_diary))
          |> Map.put("prompt_version_id", Fixtures.id(:pv_en))
          |> Map.put("model_id", Fixtures.id(:m_gpt5_mini))
        end
      )

      assert :ok =
               PromptOnSDK.log(%{
                 "prompt_key" => "diary_generation",
                 "model" => "openai/gpt-5-mini",
                 "status" => "ok"
               })

      log = assert_logged(%{"prompt_key" => "diary_generation"})
      refute Map.has_key?(log, "deployment_id")
      refute Map.has_key?(log, "prompt_version_id")
      refute Map.has_key?(log, "model_id")
    end

    test "log/1 drops with a once-per-minute warning and dropped telemetry" do
      Application.put_env(:prompton_sdk, :mode, :live)
      attach_telemetry([[:prompton, :log, :dropped]])

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :ok = PromptOnSDK.log(%{"prompt_key" => "diary_generation"})
          assert :ok = PromptOnSDK.log(%{"prompt_key" => "diary_generation"})
        end)

      assert length(Regex.scan(~r/Buffer is not running/, log)) == 1
      assert_receive {:telemetry, [:prompton, :log, :dropped], %{count: 1}, %{reason: :no_buffer}}
      assert_receive {:telemetry, [:prompton, :log, :dropped], %{count: 1}, %{reason: :no_buffer}}
      refute_receive {:prompton_log, _}, 10
    end
  end

  describe "live mode end-to-end through the buffer" do
    test "log_events/2 async path uses Buffer → client.post_events" do
      Application.delete_env(:prompton_sdk, :mode)
      FakeClient.notify(self())
      FakeClient.set(:fetch_prompts, fn _, _ -> {:error, :offline} end)
      FakeClient.set(:post_events, fn events -> ok_202(length(events)) end)
      bundle = tmp_path("prompts.production.json")
      write_snapshot_file(bundle, Fixtures.snapshot())
      start_sdk(bundle: {:file, bundle}, log: [flush_size: 1, flush_interval: 60_000])

      assert :ok =
               PromptOnSDK.log_events(%{
                 event_id: "evt-async",
                 trace_id: "trace-async",
                 event_kind: "tool_attempt",
                 status: "started"
               })

      assert_receive {:fake_client, :post_events, [[%{"event_id" => "evt-async"}]]}, 500
      refute_receive {:prompton_events, _}, 10
    end

    test "log final scrub removes retired refs added by redaction before send and retry" do
      Application.delete_env(:prompton_sdk, :mode)
      FakeClient.notify(self())
      FakeClient.set(:fetch_prompts, fn _, _ -> {:error, :offline} end)
      {:ok, agent} = Agent.start_link(fn -> :fail end)

      FakeClient.set(:post_logs, fn _items ->
        case Agent.get(agent, & &1) do
          :fail ->
            Agent.update(agent, fn _ -> :ok end)
            {:ok, %{status: 503, body: "down", headers: %{}}}

          :ok ->
            ok_202(1)
        end
      end)

      bundle = tmp_path("prompts.production.json")
      write_snapshot_file(bundle, Fixtures.snapshot())

      start_sdk(
        bundle: {:file, bundle},
        log: [
          flush_size: 1,
          flush_interval: 60_000,
          redact: fn log ->
            log
            |> Map.put("deployment_id", Fixtures.id(:d_diary))
            |> Map.put("prompt_version_id", Fixtures.id(:pv_en))
            |> Map.put("model_id", Fixtures.id(:m_gpt5_mini))
          end
        ]
      )

      assert :ok =
               PromptOnSDK.log(%{
                 "id" => "scrubbed-retry",
                 "prompt_key" => "diary_generation",
                 "model" => "openai/gpt-5-mini",
                 "status" => "ok"
               })

      assert_receive {:fake_client, :post_logs, [[first]]}, 500
      refute Map.has_key?(first, "deployment_id")
      refute Map.has_key?(first, "prompt_version_id")
      refute Map.has_key?(first, "model_id")

      eventually(fn -> PromptOnSDK.Buffer.stats().logs.count == 1 end)

      eventually(
        fn ->
          _ = PromptOnSDK.Buffer.flush()
          length(FakeClient.calls(:post_logs)) >= 2
        end,
        3_000
      )

      assert_receive {:fake_client, :post_logs, [[second]]}, 500
      refute Map.has_key?(second, "deployment_id")
      refute Map.has_key?(second, "prompt_version_id")
      refute Map.has_key?(second, "model_id")
    end

    test "track → Buffer → client.post_logs" do
      Application.delete_env(:prompton_sdk, :mode)
      FakeClient.notify(self())
      FakeClient.set(:fetch_prompts, fn _, _ -> {:error, :offline} end)
      FakeClient.set(:post_logs, fn _ -> ok_202(1) end)
      bundle = tmp_path("prompts.production.json")
      write_snapshot_file(bundle, Fixtures.snapshot())
      start_sdk(bundle: {:file, bundle}, log: [flush_size: 1, flush_interval: 60_000])

      {:ok, r} = PromptOnSDK.prompt("diary_generation")
      PromptOnSDK.track(r, %{id: "e2e"}, fn -> {:ok, Result.from_openai(@or_resp)} end)

      assert_receive {:fake_client, :post_logs, [[%{"id" => "e2e", "source" => "bundle"}]]},
                     500

      refute_receive {:prompton_log, _}, 10
    end
  end

  describe "PromptOnSDK.Test.stub/2" do
    test "builds a minimal prompt document per prompt and accumulates" do
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

      {:ok, r} = PromptOnSDK.prompt("diary_generation", %{anything: "goes"})
      assert r.model == "openai/gpt-5-mini"
      assert r.provider == :openrouter
      assert r.params == %{"temperature" => 0.2}
      assert {:ok, [_, %{content: "hello"}]} = PromptOnSDK.messages(r, %{text: "hello"})

      {:ok, stt} = PromptOnSDK.prompt("voice_transcription", %{})
      assert stt.provider == :groq and stt.kind == :text
      assert PromptOnSDK.text(stt, %{}) == {:ok, "hint"}

      assert PromptOnSDK.prompt("diary_embedding", %{}) == {:error, :unresolved}

      PromptOnSDK.track(r, %{}, fn -> {:ok, %{content: "out"}} end)
      assert_logged(%{"prompt_key" => "diary_generation", "output" => %{"content" => "out"}}, 100)
      assert PromptOnSDK.Test.logged() == []
    end

    test "put_prompt_document from file" do
      path = tmp_path("snap.json")
      File.write!(path, Jason.encode!(Fixtures.snapshot()))
      PromptOnSDK.Test.clear()
      PromptOnSDK.Test.put_prompt_document({:file, path})
      assert {:ok, _} = PromptOnSDK.prompt("chat_response", %{})
      assert_raise ArgumentError, fn -> PromptOnSDK.Test.put_prompt_document(%{"nope" => 1}) end
    end
  end
end
