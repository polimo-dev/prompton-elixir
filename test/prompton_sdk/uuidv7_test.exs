defmodule PromptOnSDK.UUIDv7Test do
  use ExUnit.Case, async: true

  alias PromptOnSDK.UUIDv7

  @format ~r/^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/

  test "generates RFC 9562 v7 format (version 7, variant 10)" do
    for _ <- 1..100 do
      id = UUIDv7.generate()
      assert id =~ @format, id
    end
  end

  test "embeds the millisecond timestamp" do
    before = System.system_time(:millisecond)
    id = UUIDv7.generate()
    after_ms = System.system_time(:millisecond)

    assert {:ok, ms} = UUIDv7.timestamp_ms(id)
    assert ms >= before and ms <= after_ms
  end

  test "ids generated at increasing times sort by time" do
    ids = for ms <- [1_000, 2_000, 3_000, 1_700_000_000_000], do: UUIDv7.generate(ms)
    assert ids == Enum.sort(ids)
    assert UUIDv7.timestamp_ms(List.last(ids)) == {:ok, 1_700_000_000_000}
  end

  test "sequential generation is monotonic-ish (timestamps never decrease)" do
    ids = for _ <- 1..200, do: UUIDv7.generate()

    timestamps =
      Enum.map(ids, fn id ->
        {:ok, ms} = UUIDv7.timestamp_ms(id)
        ms
      end)

    assert timestamps == Enum.sort(timestamps)
    assert length(Enum.uniq(ids)) == 200
  end

  test "timestamp_ms rejects garbage" do
    assert UUIDv7.timestamp_ms("nope") == :error
  end

  test "PromptOnSDK.generation_id/0 delegates" do
    assert PromptOnSDK.generation_id() =~ @format
  end
end
