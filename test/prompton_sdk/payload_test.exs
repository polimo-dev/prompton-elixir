defmodule PromptOnSDK.PayloadTest do
  use ExUnit.Case, async: true

  alias PromptOnSDK.Payload

  @config %{
    payload_defaults: %{mode: :full, sample_rate: 1.0, max_bytes: 262_144},
    hash_end_user: false,
    log: %{redact: nil}
  }

  defp gen(overrides \\ %{}) do
    Map.merge(
      %{
        "id" => "0191c000-0000-7000-8000-000000000001",
        "use_case" => "diary_generation",
        "status" => "ok",
        "stop_kind" => "stop",
        "end_user_ref" => "u_1",
        "input" => %{
          "variables" => %{"mode" => "fresh"},
          "messages" => [
            %{"role" => "system", "content" => "sys"},
            %{"role" => "user", "content" => "hello"}
          ]
        },
        "output" => %{"content" => "world", "tool_calls" => []}
      },
      overrides
    )
  end

  describe "modes" do
    test ":full keeps input/output untouched when under limits" do
      out = Payload.apply(gen(), %{mode: :full, sample_rate: 1.0, max_bytes: 1024}, @config)
      assert out["input"] == gen()["input"]
      assert out["output"] == gen()["output"]
      refute Map.has_key?(out["input"], "truncated")
    end

    test ":none drops input/output but keeps the row" do
      out = Payload.apply(gen(), %{mode: :none, sample_rate: 1.0, max_bytes: 1024}, @config)
      refute Map.has_key?(out, "input")
      refute Map.has_key?(out, "output")
      assert out["use_case"] == "diary_generation"
    end

    test ":hash replaces input/output with the pre-hashed wrapper {sha256, bytes, hashed: true}" do
      out = Payload.apply(gen(), %{mode: :hash, sample_rate: 1.0, max_bytes: 1024}, @config)
      input_json = Jason.encode!(gen()["input"])

      assert out["input"] == %{
               "sha256" => :crypto.hash(:sha256, input_json) |> Base.encode16(case: :lower),
               "bytes" => byte_size(input_json),
               "hashed" => true
             }

      assert %{"sha256" => _, "bytes" => _, "hashed" => true} = out["output"]
      assert Map.keys(out["output"]) |> Enum.sort() == ["bytes", "hashed", "sha256"]
    end

    test ":hash hashes the wrapped form of string input/output (same bytes the server would hash)" do
      g = gen(%{"input" => "raw prompt", "output" => "raw answer"})
      out = Payload.apply(g, %{mode: :hash, sample_rate: 1.0, max_bytes: 1024}, @config)
      in_json = Jason.encode!(%{"text" => "raw prompt"})
      out_json = Jason.encode!(%{"content" => "raw answer"})

      assert out["input"]["sha256"] ==
               :crypto.hash(:sha256, in_json) |> Base.encode16(case: :lower)

      assert out["input"]["bytes"] == byte_size(in_json)
      assert out["output"]["bytes"] == byte_size(out_json)
    end

    test "nil policy uses config defaults" do
      out = Payload.apply(gen(), nil, %{@config | payload_defaults: %{mode: :none}})
      refute Map.has_key?(out, "input")
    end
  end

  describe "sampling" do
    test "bucket/1 matches the server's shared vectors (first 4 bytes of sha256, not the whole digest)" do
      # Vectors shared with the server's PromptOn.Observability.PayloadPolicy.bucket/1; taking the
      # whole digest mod 10_000 would give 513/2296 instead.
      assert Payload.bucket("0192a3b4-0000-7000-8000-000000000001") == 2656
      assert Payload.bucket("00000000-0000-0000-0000-000000000000") == 8252
    end

    test "bucket/1 is first4bytes(sha256(id)) as unsigned big-endian rem 10_000 (server contract)" do
      id = "0191c000-0000-7000-8000-000000000001"
      <<n::unsigned-big-32, _::binary>> = :crypto.hash(:sha256, id)
      expected = rem(n, 10_000)

      assert Payload.bucket(id) == expected
      # Boundary: a rate just above the bucket keeps it; a rate at or below the bucket excludes it
      assert Payload.sampled?(id, (expected + 1) / 10_000)
      refute Payload.sampled?(id, expected / 10_000)

      # Differs from the old scheme that read all 32 bytes as an integer (skipped for ids where
      # both happen to agree)
      old = rem(:binary.decode_unsigned(:crypto.hash(:sha256, id)), 10_000)
      if old != expected, do: refute(Payload.bucket(id) == old)

      # Known vector: sha256("") = e3b0c442... -> 0xe3b0c442 = 3820012610 -> rem 10_000 = 2610
      assert Payload.bucket("") == 2610
    end

    test "is deterministic on sha256(id) and respects the rate" do
      ids = for i <- 1..2_000, do: "id-#{i}"
      kept = Enum.count(ids, &Payload.sampled?(&1, 0.25))
      assert kept > 400 and kept < 600, "kept #{kept}/2000 at 25%"

      # The same id always gets the same verdict
      for id <- Enum.take(ids, 50) do
        assert Payload.sampled?(id, 0.25) == Payload.sampled?(id, 0.25)
      end
    end

    test "sampled-out generations lose payload but errors and length are always kept" do
      policy = %{mode: :full, sample_rate: 0.0, max_bytes: 1024}

      refute Map.has_key?(Payload.apply(gen(), policy, @config), "input")
      assert Map.has_key?(Payload.apply(gen(%{"status" => "error"}), policy, @config), "input")

      assert Map.has_key?(
               Payload.apply(gen(%{"stop_kind" => "length"}), policy, @config),
               "input"
             )
    end

    test "rate 0 with :hash still drops (sampling happens before mode)" do
      refute Map.has_key?(
               Payload.apply(gen(), %{mode: :hash, sample_rate: 0.0}, @config),
               "input"
             )
    end
  end

  describe "truncation" do
    test "message content > max_bytes/8 is cut head+tail and marked" do
      big = String.duplicate("a", 500) <> String.duplicate("z", 500)
      g = gen(%{"input" => %{"messages" => [%{"role" => "user", "content" => big}]}})
      out = Payload.apply(g, %{mode: :full, sample_rate: 1.0, max_bytes: 800}, @config)

      [msg] = out["input"]["messages"]
      assert byte_size(msg["content"]) <= 100
      assert msg["truncated"] == true
      assert out["input"]["truncated"] == true
      assert String.starts_with?(msg["content"], "aaa")
      assert String.ends_with?(msg["content"], "zzz")
      assert msg["content"] =~ "[truncated"
    end

    test "input messages JSON > max_bytes stubs middle messages, keeping first and last" do
      msgs =
        for i <- 1..20,
            do: %{"role" => "user", "content" => "#{i}:" <> String.duplicate("x", 200)}

      g = gen(%{"input" => %{"messages" => msgs}})
      # One message is ≤ max/8 = 256; the JSON total is ≈ 20×230 > 2048
      out = Payload.apply(g, %{mode: :full, sample_rate: 1.0, max_bytes: 2048}, @config)

      result = out["input"]["messages"]
      assert length(result) == 20
      assert hd(result)["content"] == hd(msgs)["content"]
      assert List.last(result)["content"] == List.last(msgs)["content"]
      assert Enum.at(result, 1)["truncated"] == true
      assert Enum.at(result, 1)["content"] =~ "[truncated 202 bytes]"
      assert byte_size(Jason.encode!(result)) <= 2048
      assert out["input"]["truncated"] == true
    end

    test "when stubs alone cannot fit, middle messages are dropped (first + marker + tail kept intact)" do
      msgs =
        for i <- 1..10, do: %{"role" => "user", "content" => "#{i}:" <> String.duplicate("x", 90)}

      g = gen(%{"input" => %{"messages" => msgs}})
      # One message is 100B ≤ max/8 = 100; the JSON total is ~1290 > 800, and even with 8 stubs
      # ~840 > 800
      out = Payload.apply(g, %{mode: :full, sample_rate: 1.0, max_bytes: 800}, @config)

      result = out["input"]["messages"]
      assert length(result) < 10
      assert hd(result) == hd(msgs)
      assert List.last(result) == List.last(msgs)
      assert %{"role" => "system", "truncated" => true, "content" => marker} = Enum.at(result, 1)
      assert marker =~ ~r/\[\d+ messages truncated\]/
      assert byte_size(Jason.encode!(result)) <= 800
      assert out["input"]["truncated"] == true
    end

    # The limits the server (`Ingest.Truncation`) re-validates; SDK truncation output must always
    # satisfy them.
    defp assert_within_server_limits(out, max) do
      input = out["input"] || %{}
      output = out["output"] || %{}

      for msg <- input["messages"] || [], do: assert_size(msg["content"], max(div(max, 8), 64))
      assert_size(input["messages"], max)
      assert_size(input["text"], max)
      assert_size(input["variables"], div(max, 4))
      assert_size(output["content"], div(max, 4))
      assert_size(output["tool_calls"], div(max, 4))
      out
    end

    # Strings are measured in bytes, everything else in JSON bytes (nil passes).
    defp assert_size(nil, _limit), do: :ok
    defp assert_size(bin, limit) when is_binary(bin), do: assert(byte_size(bin) <= limit)
    defp assert_size(value, limit), do: assert(byte_size(Jason.encode!(value)) <= limit)

    test "adversarial inputs still satisfy the server's JSON-byte limits after SDK truncation" do
      policy = fn max -> %{mode: :full, sample_rate: 1.0, max_bytes: max} end

      cases = [
        # Many medium-sized messages (each under the per-message limit, total over it from JSON
        # overhead)
        {1024, for(i <- 1..300, do: %{"role" => "user", "content" => "m#{i} " <> dup("y", 100)})},
        # Very many short messages: stubs alone do not fit, so dropping is required
        {1024, for(i <- 1..2_000, do: %{"role" => "user", "content" => "#{i}"})},
        # One huge message (with quotes and newlines that need escaping)
        {1024, [%{"role" => "user", "content" => dup("\"\n\\", 50_000)}]},
        # System + a huge last message
        {2048,
         [
           %{"role" => "system", "content" => dup("s", 300)},
           %{"role" => "user", "content" => dup("u", 100_000)}
         ]},
        # Unicode (multibyte, no escaping); the Korean text is kept on purpose as a 3-byte sample
        {1024, for(_ <- 1..50, do: %{"role" => "user", "content" => dup("한글😀", 60)})},
        # Control characters (inflated to 6-byte \uXXXX in JSON)
        {1024, for(_ <- 1..20, do: %{"role" => "user", "content" => dup(<<1>>, 120)})},
        # A non-content key of the first message is huge (does not fit even with the content
        # emptied -> only role is kept)
        {1024,
         [
           %{"role" => "system", "name" => dup("n", 5_000), "content" => "x"},
           %{"role" => "user", "content" => "y"}
         ]},
        # Non-string content (multimodal parts)
        {1024,
         for(
           _ <- 1..30,
           do: %{"role" => "user", "content" => [%{"type" => "text", "text" => dup("p", 200)}]}
         )}
      ]

      for {max, msgs} <- cases do
        g =
          gen(%{
            "input" => %{"messages" => msgs, "variables" => %{"v" => dup("z", max)}},
            "output" => %{
              "content" => dup("o\"", max),
              "tool_calls" =>
                for(
                  i <- 1..5,
                  do: %{
                    "id" => "c#{i}",
                    "function" => %{"name" => "fn#{i}", "arguments" => dup("{\"k\":1}", max)}
                  }
                )
            }
          })

        out = Payload.apply(g, policy.(max), @config)
        assert_within_server_limits(out, max)
        assert out["input"]["truncated"] == true
        assert out["output"]["truncated"] == true
        # The first message (the system prompt slot) always keeps its role
        assert hd(out["input"]["messages"])["role"] == hd(msgs)["role"]

        # Drops happen only in the middle: the last message survives (usually), or the budget ran
        # out and the marker is simply the last entry
        last = List.last(out["input"]["messages"])
        assert last["role"] == List.last(msgs)["role"] or last["content"] =~ "messages truncated"
      end
    end

    test "string input/output are always wrapped as objects, truncated or not" do
      g = gen(%{"input" => "short prompt", "output" => "short answer"})
      out = Payload.apply(g, %{mode: :full, sample_rate: 1.0, max_bytes: 4096}, @config)
      assert out["input"] == %{"text" => "short prompt"}
      assert out["output"] == %{"content" => "short answer"}

      g = gen(%{"input" => dup("i", 5_000), "output" => dup("o", 5_000)})
      out = Payload.apply(g, %{mode: :full, sample_rate: 1.0, max_bytes: 1024}, @config)
      assert %{"text" => text, "truncated" => true} = out["input"]
      assert byte_size(text) <= 1024
      assert %{"content" => content, "truncated" => true} = out["output"]
      assert byte_size(content) <= 256
      assert_within_server_limits(out, 1024)
    end

    test "input.text in a map is capped at max_bytes" do
      g = gen(%{"input" => %{"text" => dup("t", 3_000)}})
      out = Payload.apply(g, %{mode: :full, sample_rate: 1.0, max_bytes: 1024}, @config)
      assert byte_size(out["input"]["text"]) <= 1024
      assert out["input"]["truncated"] == true
    end

    test "tool_calls that cannot be shrunk to fit are replaced by a marker" do
      calls =
        for i <- 1..50,
            do: %{
              "id" => "call-#{i}",
              "type" => "function",
              "function" => %{"name" => "f", "arguments" => "{}"}
            }

      g = gen(%{"output" => %{"tool_calls" => calls}})
      out = Payload.apply(g, %{mode: :full, sample_rate: 1.0, max_bytes: 1024}, @config)
      assert [%{"truncated" => true, "bytes" => bytes}] = out["output"]["tool_calls"]
      assert bytes == byte_size(Jason.encode!(calls))
      assert out["output"]["truncated"] == true
    end

    defp dup(s, n), do: String.duplicate(s, n)

    test "variables over max_bytes/4 are replaced by a hash stub" do
      g = gen(%{"input" => %{"variables" => %{"t" => String.duplicate("v", 1000)}}})
      out = Payload.apply(g, %{mode: :full, sample_rate: 1.0, max_bytes: 400}, @config)
      assert %{"truncated" => true, "sha256" => _, "bytes" => _} = out["input"]["variables"]
    end

    test "output content > max_bytes/4 truncated; tool_calls arguments truncated" do
      g =
        gen(%{
          "output" => %{
            "content" => String.duplicate("o", 1000),
            "tool_calls" => [
              %{
                "id" => "c1",
                "function" => %{"name" => "f", "arguments" => String.duplicate("{", 600)}
              }
            ]
          }
        })

      out = Payload.apply(g, %{mode: :full, sample_rate: 1.0, max_bytes: 800}, @config)
      assert byte_size(out["output"]["content"]) <= 200
      assert out["output"]["truncated"] == true
      [call] = out["output"]["tool_calls"]
      assert call["id"] == "c1"
      assert call["function"]["arguments"] =~ "[truncated"
      assert byte_size(Jason.encode!(out["output"]["tool_calls"])) <= 200
    end

    test "truncate_binary is UTF-8 safe" do
      # A 3-byte Korean character on purpose: a byte-based cut can land mid-codepoint
      s = String.duplicate("한", 100)
      {out, true} = Payload.truncate_binary(s, 60)
      assert String.valid?(out)
      assert byte_size(out) <= 60
      assert {^s, false} = Payload.truncate_binary(s, 1_000)
    end

    test "error.message capped at 2KB" do
      g =
        gen(%{
          "status" => "error",
          "error" => %{"kind" => "app", "message" => String.duplicate("e", 5_000)}
        })

      out = Payload.apply(g, nil, @config)
      assert byte_size(out["error"]["message"]) <= 2_048
    end
  end

  describe "hooks" do
    test "hash_end_user hashes end_user_ref" do
      out = Payload.apply(gen(), nil, %{@config | hash_end_user: true})
      assert out["end_user_ref"] == :crypto.hash(:sha256, "u_1") |> Base.encode16(case: :lower)
    end

    test "redact hook is applied last" do
      redact = fn g -> put_in(g, ["input", "messages"], []) end
      out = Payload.apply(gen(), nil, %{@config | log: %{redact: redact}})
      assert out["input"]["messages"] == []
    end

    test "redact hook raising drops the payload instead of crashing" do
      redact = fn _ -> raise "boom" end
      out = Payload.apply(gen(), nil, %{@config | log: %{redact: redact}})
      refute Map.has_key?(out, "input")
      assert out["use_case"] == "diary_generation"
    end
  end
end
