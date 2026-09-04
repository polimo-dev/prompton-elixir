defmodule PromptOnSDK.StopKindTest do
  use ExUnit.Case, async: true
  doctest PromptOnSDK.StopKind

  alias PromptOnSDK.StopKind

  test "normalize/1 follows the §5.7 table" do
    # OpenRouter / OpenAI
    assert StopKind.normalize("stop") == :stop
    assert StopKind.normalize("length") == :length
    assert StopKind.normalize("tool_calls") == :tool_call
    assert StopKind.normalize("content_filter") == :content_filter
    # Anthropic
    assert StopKind.normalize("end_turn") == :stop
    assert StopKind.normalize("max_tokens") == :length
    assert StopKind.normalize("tool_use") == :tool_call
    assert StopKind.normalize("stop_sequence") == :stop
    # everything else
    assert StopKind.normalize("function_call") == :other
    assert StopKind.normalize("error") == :other
    assert StopKind.normalize("") == :other
    assert StopKind.normalize(nil) == :other
    assert StopKind.normalize(42) == :other
  end

  test "normalize/1 is case/whitespace insensitive and accepts atoms" do
    assert StopKind.normalize(" STOP ") == :stop
    assert StopKind.normalize(:max_tokens) == :length
    assert StopKind.normalize(:tool_calls) == :tool_call
  end

  test "normalize/1 is idempotent: canonical values (strings and atoms) pass through" do
    for kind <- [:stop, :length, :tool_call, :content_filter, :other] do
      assert StopKind.normalize(kind) == kind
      assert StopKind.normalize(Atom.to_string(kind)) == kind
      assert kind |> StopKind.normalize() |> StopKind.normalize() == kind
    end

    # Feeding a normalized value back in as a string yields the same value (Generation.build
    # re-normalizes outcome.stop_kind)
    assert "tool_calls" |> StopKind.normalize() |> Atom.to_string() |> StopKind.normalize() ==
             :tool_call
  end

  test "truncated?/1 is true only for :length" do
    assert StopKind.truncated?(:length)
    assert StopKind.truncated?("length")
    assert StopKind.truncated?("max_tokens")
    refute StopKind.truncated?(:stop)
    refute StopKind.truncated?(:tool_call)
    refute StopKind.truncated?("tool_calls")
    refute StopKind.truncated?(:content_filter)
    refute StopKind.truncated?(:other)
    refute StopKind.truncated?(nil)
  end
end
