defmodule PromptOnSDK.AdaptersTest do
  use ExUnit.Case, async: true

  alias PromptOnSDK.{Fixtures, Generic, OpenRouter, Resolver}

  defp resolve(key, opts \\ []) do
    {:ok, r} = Resolver.resolve(Fixtures.snapshot_data(), key, opts)
    r
  end

  describe "OpenRouter.request_body/3" do
    test "assembles model/messages/params/provider and usage.include" do
      r = resolve("diary_generation", prompt: "ko")
      msgs = [%{"role" => "user", "content" => "hi"}]
      body = OpenRouter.request_body(r, msgs, %{"max_tokens" => 2048})

      assert body["model"] == "anthropic/claude-sonnet-4"
      assert body["messages"] == msgs
      assert body["temperature"] == 0.4
      assert body["max_tokens"] == 2048
      assert body["provider"] == %{"only" => ["Anthropic"], "allow_fallbacks" => false}
      assert body["usage"] == %{"include" => true}
    end

    test "provider.only nil is preserved and serializes as null" do
      r = %{
        resolve("diary_generation")
        | effective_provider_options: %{"only" => nil, "allow_fallbacks" => true}
      }

      body = OpenRouter.request_body(r, [])
      assert body["provider"] == %{"only" => nil, "allow_fallbacks" => true}
      json = Jason.encode!(body)
      assert json =~ ~s("only":null)
    end

    test "provider key omitted when effective options are empty; overrides merge on top" do
      r = resolve("voice_transcription")
      assert r.effective_provider_options == %{}

      body =
        OpenRouter.request_body(r, [], %{
          "temperature" => 0.1,
          stream: true,
          usage: %{"include" => false}
        })

      refute Map.has_key?(body, "provider")
      assert body["stream"] == true
      assert body["usage"] == %{"include" => false}
      assert body["temperature"] == 0.1
    end

    test "nil params are dropped from the body" do
      r = %{
        resolve("chat_response")
        | effective_params: %{"temperature" => nil, "top_p" => 0.9}
      }

      body = OpenRouter.request_body(r, [])
      refute Map.has_key?(body, "temperature")
      assert body["top_p"] == 0.9
    end
  end

  describe "OpenRouter.outcome/1" do
    @resp %{
      "id" => "gen-1",
      "model" => "anthropic/claude-sonnet-4",
      "provider" => "Anthropic",
      "choices" => [
        %{
          "finish_reason" => "stop",
          "native_finish_reason" => "end_turn",
          "message" => %{"role" => "assistant", "content" => "hello", "tool_calls" => nil}
        }
      ],
      "usage" => %{
        "prompt_tokens" => 10,
        "completion_tokens" => 5,
        "cost" => 0.0012,
        "is_byok" => false
      }
    }

    test "extracts content, tokens, cost from provider" do
      o = OpenRouter.outcome(@resp)
      assert o.content == "hello"
      assert o.finish_reason == "stop"
      assert o.stop_kind == :stop
      assert o.usage.input_tokens == 10
      assert o.usage.output_tokens == 5
      assert o.cost_usd == 0.0012
      assert o.cost_source == :provider
      assert o.is_byok == false
      assert o.model_used == "anthropic/claude-sonnet-4"
      assert o.upstream_provider == "Anthropic"
      assert o.raw == @resp
    end

    test "BYOK uses cost_details.upstream_inference_cost" do
      resp =
        put_in(@resp, ["usage"], %{
          "prompt_tokens" => 1,
          "completion_tokens" => 1,
          "cost" => 0.0,
          "is_byok" => true,
          "cost_details" => %{"upstream_inference_cost" => 0.5}
        })

      o = OpenRouter.outcome(resp)
      assert o.cost_usd == 0.5
      assert o.is_byok == true
      assert o.cost_source == :provider
    end

    test "missing usage → cost unknown; length/tool_calls normalize" do
      resp =
        @resp
        |> Map.delete("usage")
        |> put_in(["choices", Access.at(0), "finish_reason"], "length")

      o = OpenRouter.outcome(resp)
      assert o.cost_usd == nil
      assert o.cost_source == :unknown
      assert o.usage.input_tokens == nil
      assert o.stop_kind == :length

      resp = put_in(@resp, ["choices", Access.at(0), "finish_reason"], "tool_calls")
      assert OpenRouter.outcome(resp).stop_kind == :tool_call
    end

    test "empty choices" do
      o = OpenRouter.outcome(%{"choices" => []})
      assert o.content == nil
      assert o.stop_kind == :other
    end
  end

  describe "Generic.outcome/1" do
    test "normalizes atom or string keys" do
      o =
        Generic.outcome(%{
          "input_tokens" => 3,
          output_tokens: 0,
          content: "txt",
          finish_reason: "max_tokens"
        })

      assert o.usage.input_tokens == 3
      assert o.usage.output_tokens == 0
      assert o.stop_kind == :length
      assert o.cost_source == :unknown

      o = Generic.outcome(%{input_tokens: 3, output_tokens: 0, cost_usd: 0.01})
      assert o.cost_source == :provider
      assert o.stop_kind == :other
    end
  end
end
