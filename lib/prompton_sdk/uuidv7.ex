defmodule PromptOnSDK.UUIDv7 do
  @moduledoc """
  RFC 9562 UUIDv7 generator with no external dependencies.

  The Generation `id` is an idempotency key the SDK issues up front (§5.7 `uuid_v7_primary_key`,
  §6.4), so v7, which sorts chronologically, is used. Layout: 48-bit unix milliseconds | 4-bit
  version (7) | 12-bit random | 2-bit variant (10) | 62-bit random. Returned in lowercase hex
  with dashes (`019a…`).

  Order within the same millisecond is not guaranteed (random). Across different milliseconds,
  string order = time order.
  """

  @doc "A new UUIDv7 string."
  @spec generate() :: String.t()
  def generate, do: generate(System.system_time(:millisecond))

  @doc false
  @spec generate(non_neg_integer()) :: String.t()
  def generate(unix_ms) when is_integer(unix_ms) and unix_ms >= 0 do
    <<rand_a::12, rand_b::62, _::6>> = :crypto.strong_rand_bytes(10)

    <<a::32, b::16, c::16, d::16, e::48>> =
      <<unix_ms::48, 7::4, rand_a::12, 2::2, rand_b::62>>

    :io_lib.format("~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", [a, b, c, d, e])
    |> IO.iodata_to_binary()
  end

  @doc "Extracts the unix milliseconds from a UUIDv7 string. `:error` when not in that format."
  @spec timestamp_ms(String.t()) :: {:ok, non_neg_integer()} | :error
  def timestamp_ms(<<hex::binary-size(8), "-", hex2::binary-size(4), "-", rest::binary>>)
      when byte_size(rest) == 22 do
    case Integer.parse(hex <> hex2, 16) do
      {ms, ""} -> {:ok, ms}
      _ -> :error
    end
  end

  def timestamp_ms(_), do: :error
end
