defmodule PromptOnSDK.ParamsTest do
  use ExUnit.Case, async: true
  doctest PromptOnSDK.Params

  alias PromptOnSDK.Params

  test "override wins, base keys survive" do
    assert Params.merge(%{"temperature" => 0.5, "max_tokens" => 100}, %{"temperature" => 0.9}) ==
             %{"temperature" => 0.9, "max_tokens" => 100}
  end

  test "keys are normalized to strings" do
    assert Params.merge(%{temperature: 0.5}, %{"temperature" => 0.7, top_p: 1}) ==
             %{"temperature" => 0.7, "top_p" => 1}
  end

  test "explicit nil in the override is preserved (provider.only: null)" do
    merged = Params.merge(%{"only" => ["Anthropic"], "allow_fallbacks" => true}, %{"only" => nil})
    assert merged == %{"only" => nil, "allow_fallbacks" => true}
    assert Map.has_key?(merged, "only")
    assert Jason.encode!(merged) =~ ~s("only":null)
  end

  test "explicit nil in the base survives when not overridden" do
    assert Params.merge(%{"only" => nil}, %{"allow_fallbacks" => false}) ==
             %{"only" => nil, "allow_fallbacks" => false}
  end

  test "shallow: nested maps are replaced, not merged" do
    assert Params.merge(%{"response_format" => %{"type" => "json", "schema" => 1}}, %{
             "response_format" => %{"type" => "text"}
           }) == %{"response_format" => %{"type" => "text"}}
  end

  test "nil / non-map inputs are treated as empty" do
    assert Params.merge(nil, %{"a" => 1}) == %{"a" => 1}
    assert Params.merge(%{"a" => 1}, nil) == %{"a" => 1}
    assert Params.merge(nil, nil) == %{}
    assert Params.stringify_keys(nil) == %{}
  end
end
