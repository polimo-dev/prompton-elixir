defmodule PromptOnSDK.Payload do
  @moduledoc """
  Generation payload policy (§5.7, §7.5), applied by the SDK at enqueue time. The server ingest
  re-validates it, but the SDK has to apply it first so that the raw text never travels over the
  network ("if the SDK option is more conservative, the SDK wins").

  The input is a **string-keyed** generation map in the §6.4 format; the policy is the snapshot
  UseCase's `payload_policy` (`%{mode: :full | :hash | :none, sample_rate: float, max_bytes: int}`;
  `config.payload_defaults` when `nil`).

  ## Order

  1. **Keep decision**: always keep when `status == "error"` or `stop_kind == "length"`; otherwise
     keep when `bucket(id) < round(sample_rate × 10_000)`, where
     `bucket(id) = first4bytes(sha256(id)) as unsigned big-endian rem 10_000` (deterministic: a
     resend gets the same decision; the same formula as the server's `PayloadPolicy.bucket/1`).
     When not kept, `input`/`output` are removed (the narrow Generation row always remains).
  2. **Object wrapping**: a string `input` is always wrapped as `%{"text" => str}` and a string
     `output` as `%{"content" => str}` (regardless of truncation; the server wraps an incoming
     string the same way).
  3. **mode**
     * `:none`: remove `input`/`output`.
     * `:hash`: replace `input`/`output` with the **pre-hashed wrapper**
       `%{"sha256" => hex, "bytes" => n, "hashed" => true}` (hash and size are computed over the
       canonical JSON `Jason.encode!/1` bytes of the wrapped value). Raw text and variables are
       not sent. The server recognizes a map whose keys are exactly `sha256` and `bytes`
       (+ optional `hashed: true`) as pre-hashed `input`/`output`, stores it as is in
       `input_sha256`/`bytes_in` (or output), and sets `payload_state :hashed`.
     * `:full`: truncation (units: totals, output, and variables are **JSON-encoded bytes**; a
       single message is the `content` string's bytes): a single message `content` ≤
       `max_bytes/8`, `input.messages` (JSON) ≤ `max_bytes`, `input.text` ≤ `max_bytes`,
       `input.variables` (JSON) ≤ `max_bytes/4`, `output.content` ≤ `max_bytes/4`,
       `output.tool_calls` (JSON) ≤ `max_bytes/4`.
       The excess is cut from the middle, keeping the head and tail (`…[truncated N bytes]…`) +
       `"truncated": true`.
       When the total is exceeded, the contents from the second message onward (the system prompt
       and the last message are preserved) are emptied into stubs, and if it still overflows, the
       middle messages are dropped (first message + `…[N messages truncated]…` marker + as much of
       the original from the tail as fits the budget). The result always satisfies the server
       caps, so the server only re-validates and never cuts again.
  4. `error.message` ≤ 2KB; `context`/`metadata` are left to the server caps (2KB/4KB).
  5. When `hash_end_user: true`, `end_user_ref` becomes a sha256 hex (an unkeyed hash, for stable
     identification within a project; this is not anonymization).
  6. The `log.redact` hook (`fn map -> map`) is applied **last**. If the hook raises, the raw text
     (`input`/`output`) is discarded and a warning is logged.
  """

  require Logger

  @error_message_max 2_048
  @sample_scale 10_000

  @type policy :: %{
          optional(:mode) => :full | :hash | :none,
          optional(:sample_rate) => number(),
          optional(:max_bytes) => pos_integer()
        }

  @doc """
  Returns the generation map with the policy applied. `config` is a `PromptOnSDK.Config.t()`
  (uses `payload_defaults`, `hash_end_user`, `log.redact`).
  """
  @spec apply(map(), policy() | nil, map()) :: map()
  def apply(gen, policy, config) when is_map(gen) do
    policy = normalize_policy(policy, config)

    gen
    |> apply_mode(policy)
    |> cap_error_message()
    |> hash_end_user(config)
    |> redact(config)
  end

  @doc "Policy normalization (snapshot value ⊕ defaults). `sample_rate` is clamped to 0..1."
  @spec normalize_policy(policy() | nil, map()) :: %{
          mode: atom(),
          sample_rate: float(),
          max_bytes: pos_integer()
        }
  def normalize_policy(policy, config) do
    defaults =
      Map.get(config, :payload_defaults, %{mode: :full, sample_rate: 1.0, max_bytes: 262_144})

    policy = if is_map(policy), do: policy, else: %{}
    pick = fn key -> Map.get(policy, key) || Map.get(defaults, key) end

    %{
      mode: normalize_mode(pick.(:mode)),
      sample_rate: normalize_rate(pick.(:sample_rate)),
      max_bytes: normalize_max_bytes(pick.(:max_bytes))
    }
  end

  defp normalize_mode(m) when m in [:full, :hash, :none], do: m
  defp normalize_mode(_), do: :full

  defp normalize_rate(r) when is_number(r), do: r |> max(0) |> min(1) |> then(&(&1 / 1))
  defp normalize_rate(_), do: 1.0

  defp normalize_max_bytes(n) when is_integer(n) and n > 0, do: n
  defp normalize_max_bytes(_), do: 262_144

  @doc """
  Whether to keep this generation's raw text. Errors/truncations always; otherwise
  `bucket(id) < round(rate × 10_000)`.
  """
  @spec keep?(map(), float()) :: boolean()
  def keep?(gen, rate) do
    cond do
      str(Map.get(gen, "status")) == "error" -> true
      str(Map.get(gen, "stop_kind")) == "length" -> true
      rate >= 1.0 -> true
      rate <= 0.0 -> false
      true -> sampled?(Map.get(gen, "id"), rate)
    end
  end

  defp str(nil), do: nil
  defp str(v) when is_atom(v), do: Atom.to_string(v)
  defp str(v) when is_binary(v), do: v
  defp str(v), do: to_string(v)

  @doc false
  def sampled?(id, rate), do: bucket(id) < round(rate * @sample_scale)

  @doc """
  Sampling bucket 0..9999: `first4bytes(sha256(id))` read as an unsigned big-endian integer,
  `rem 10_000`. The same formula as the server's `PromptOn.Observability.PayloadPolicy.bucket/1`,
  so the decision is identical whichever side makes it.
  """
  @spec bucket(String.t() | nil) :: non_neg_integer()
  def bucket(id) do
    <<n::unsigned-big-32, _::binary>> = :crypto.hash(:sha256, to_string(id || ""))
    rem(n, @sample_scale)
  end

  # ---------------------------------------------------------------------------
  # mode

  defp apply_mode(gen, %{mode: :none}), do: drop_payload(gen)

  defp apply_mode(gen, policy) do
    if keep?(gen, policy.sample_rate) do
      gen = wrap_payload(gen)

      case policy.mode do
        :hash -> hash_payload(gen)
        :full -> truncate_payload(gen, policy.max_bytes)
      end
    else
      drop_payload(gen)
    end
  end

  defp drop_payload(gen), do: Map.drop(gen, ["input", "output"])

  # String input/output is always wrapped in an object, regardless of truncation (the server
  # wraps it the same way).
  defp wrap_payload(gen) do
    gen
    |> wrap_binary("input", "text")
    |> wrap_binary("output", "content")
  end

  defp wrap_binary(gen, key, inner) do
    case Map.get(gen, key) do
      bin when is_binary(bin) -> Map.put(gen, key, %{inner => bin})
      _ -> gen
    end
  end

  defp hash_payload(gen) do
    gen
    |> replace_with_hash("input")
    |> replace_with_hash("output")
  end

  defp replace_with_hash(gen, key) do
    case Map.get(gen, key) do
      nil ->
        gen

      value ->
        json = canonical_json(value)

        Map.put(gen, key, %{
          "sha256" => sha256_hex(json),
          "bytes" => byte_size(json),
          "hashed" => true
        })
    end
  end

  # ---------------------------------------------------------------------------
  # :full truncation
  #
  # Caps (the same rules as the server's `Ingest.Truncation`):
  #   a single message's content (string bytes; JSON bytes if not a string) ≤ max/8
  #   input.messages (JSON bytes) ≤ max, input.text (bytes) ≤ max, input.variables (JSON) ≤ max/4
  #   output.content (bytes) ≤ max/4, output.tool_calls (JSON) ≤ max/4
  # We guarantee here that the result satisfies the caps after truncation (the server only
  # re-validates and never cuts again).

  defp truncate_payload(gen, max_bytes) do
    gen
    |> Map.update("input", nil, &truncate_input(&1, max_bytes))
    |> Map.update("output", nil, &truncate_output(&1, max_bytes))
    |> Enum.reject(fn {k, v} -> k in ["input", "output"] and is_nil(v) end)
    |> Map.new()
  end

  defp truncate_input(nil, _), do: nil

  defp truncate_input(input, max_bytes) when is_map(input) do
    per_message = max(div(max_bytes, 8), 64)
    var_limit = max(div(max_bytes, 4), 64)

    {messages, t1} = truncate_messages(Map.get(input, "messages"), per_message, max_bytes)
    {text, t2} = truncate_text(Map.get(input, "text"), max_bytes)
    {variables, t3} = truncate_variables(Map.get(input, "variables"), var_limit)

    input
    |> put_unless_nil("messages", messages)
    |> put_unless_nil("text", text)
    |> put_unless_nil("variables", variables)
    |> mark_truncated(t1 or t2 or t3)
  end

  defp truncate_input(other, _), do: other

  defp truncate_text(text, limit) when is_binary(text), do: truncate_binary(text, limit)
  defp truncate_text(other, _), do: {other, false}

  defp truncate_messages(nil, _, _), do: {nil, false}

  defp truncate_messages(messages, per_message, total_limit) when is_list(messages) do
    {messages, truncated?} =
      Enum.map_reduce(messages, false, fn msg, acc ->
        {msg, t} = truncate_message(msg, per_message)
        {msg, acc or t}
      end)

    if list_json_size(messages) <= total_limit do
      {messages, truncated?}
    else
      {fit_messages(messages, total_limit), true}
    end
  end

  defp truncate_messages(other, _, _), do: {other, false}

  # Total exceeded: (1) empty the contents from the second message onward into stubs (first =
  # system prompt, last = latest input; both preserved), and (2) if it still overflows (very many
  # messages, or JSON overhead/escaping), drop the middle messages entirely (the same shape as the
  # server's `drop_middle_messages`: first message + marker + as many **original** messages from
  # the tail as fit the budget). The result's JSON bytes are always ≤ `limit`.
  defp fit_messages(messages, limit) do
    stubbed = stub_middle(messages, limit)
    if list_json_size(stubbed) <= limit, do: stubbed, else: drop_middle(messages, limit)
  end

  defp stub_middle(messages, limit) do
    count = length(messages)
    total = list_json_size(messages)

    {stubbed, _} =
      messages
      |> Enum.with_index()
      |> Enum.map_reduce(total, fn
        {msg, idx}, running when idx > 0 and idx < count - 1 and running > limit ->
          bytes = message_content_bytes(msg)

          stub =
            msg |> put_message_content("…[truncated #{bytes} bytes]…") |> mark_truncated(true)

          {stub, running - json_size(msg) + json_size(stub)}

        {msg, _}, running ->
          {msg, running}
      end)

    stubbed
  end

  # First message + truncation marker message + as many from the tail as fit the budget. If the
  # first message alone overflows, halve its content repeatedly; if it still overflows with no
  # content (other keys are large), keep only the role. Failing that, only the marker; if even the
  # marker does not fit, an empty list.
  defp drop_middle([], _limit), do: []

  defp drop_middle([first | rest], limit) do
    # The marker size uses the digit count of the worst case (everything dropped); the actual drop
    # count is at most that, so the result stays within budget too.
    marker = %{"role" => "system", "content" => marker_text(length(rest)), "truncated" => true}
    base = list_json_size([first, marker])

    if base <= limit do
      kept_tail = tail_within(rest, limit - base)
      dropped = length(rest) - length(kept_tail)
      [first, Map.put(marker, "content", marker_text(dropped)) | kept_tail]
    else
      case shrink_first(first) do
        ^first ->
          marker = Map.put(marker, "content", marker_text(length(rest) + 1))
          if list_json_size([marker]) <= limit, do: [marker], else: []

        smaller ->
          drop_middle([smaller | rest], limit)
      end
    end
  end

  # Halve the content if there is any, otherwise keep only the role. Returns the message unchanged
  # when there is nothing left to shrink (the caller uses that as the stop condition).
  defp shrink_first(msg) do
    case message_content_bytes(msg) do
      0 -> minimal_message(msg)
      bytes -> msg |> truncate_message(div(bytes, 2)) |> elem(0)
    end
  end

  defp minimal_message(msg) do
    role = Map.get(msg, "role") || Map.get(msg, :role)
    mark_truncated(if(is_nil(role), do: %{}, else: %{"role" => role}), true)
  end

  # As many messages from the tail as fit the budget (JSON bytes + comma).
  defp tail_within(messages, budget) do
    {kept, _} =
      messages
      |> Enum.reverse()
      |> Enum.reduce_while({[], budget}, fn msg, {kept, left} ->
        size = json_size(msg) + 1
        if size <= left, do: {:cont, {[msg | kept], left - size}}, else: {:halt, {kept, left}}
      end)

    kept
  end

  defp marker_text(dropped), do: "…[#{dropped} messages truncated]…"

  defp truncate_message(msg, limit) when is_map(msg) do
    content = message_content(msg)

    cond do
      is_binary(content) ->
        {bin, t} = truncate_binary(content, limit)
        msg = put_message_content(msg, bin)
        {mark_truncated(msg, t), t}

      is_nil(content) ->
        {msg, false}

      true ->
        json = canonical_json(content)

        if byte_size(json) > limit do
          {bin, _} = truncate_binary(json, limit)
          {msg |> put_message_content(bin) |> mark_truncated(true), true}
        else
          {msg, false}
        end
    end
  end

  defp truncate_message(other, _), do: {other, false}

  defp message_content(msg) when is_map(msg),
    do: Map.get(msg, "content") || Map.get(msg, :content)

  defp message_content(_), do: nil

  defp put_message_content(msg, content) do
    if Map.has_key?(msg, :content) and not Map.has_key?(msg, "content") do
      Map.put(msg, :content, content)
    else
      Map.put(msg, "content", content)
    end
  end

  defp message_content_bytes(msg) do
    case message_content(msg) do
      nil -> 0
      bin when is_binary(bin) -> byte_size(bin)
      other -> byte_size(canonical_json(other))
    end
  end

  # Jason encodes without whitespace, `[a,b,c]`: sum of the element JSON + commas + brackets.
  defp list_json_size([]), do: 2
  defp list_json_size(list), do: Enum.reduce(list, 1, fn el, acc -> acc + json_size(el) + 1 end)

  defp truncate_variables(nil, _), do: {nil, false}

  defp truncate_variables(vars, limit) do
    json = canonical_json(vars)

    if byte_size(json) <= limit do
      {vars, false}
    else
      {%{"truncated" => true, "sha256" => sha256_hex(json), "bytes" => byte_size(json)}, true}
    end
  end

  defp truncate_output(nil, _), do: nil

  defp truncate_output(output, max_bytes) when is_map(output) do
    limit = max(div(max_bytes, 4), 64)

    {content, t1} =
      case Map.get(output, "content") do
        bin when is_binary(bin) -> truncate_binary(bin, limit)
        other -> {other, false}
      end

    {tool_calls, t2} = truncate_tool_calls(Map.get(output, "tool_calls"), limit)

    output
    |> put_unless_nil("content", content)
    |> put_unless_nil("tool_calls", tool_calls)
    |> mark_truncated(t1 or t2)
  end

  defp truncate_output(other, _), do: other

  defp truncate_tool_calls(nil, _), do: {nil, false}

  defp truncate_tool_calls(calls, limit) when is_list(calls) do
    if json_size(calls) <= limit do
      {calls, false}
    else
      # arguments budget = (cap − JSON size without the arguments) / count. If escaping overhead
      # still makes it overflow, halve the budget repeatedly; if it still does not fit, replace
      # tool_calls itself with a single marker entry.
      overhead = calls |> Enum.map(&put_arguments(&1, "")) |> json_size()
      budget = div(max(limit - overhead, 0), max(length(calls), 1))
      {shrink_tool_calls(calls, budget, limit), true}
    end
  end

  defp truncate_tool_calls(other, _), do: {other, false}

  defp shrink_tool_calls(calls, budget, limit) when budget >= 32 do
    shrunk =
      Enum.map(calls, fn
        %{"function" => %{"arguments" => args}} = call when is_binary(args) ->
          {args, _} = truncate_binary(args, budget)
          put_arguments(call, args)

        call ->
          call
      end)

    if json_size(shrunk) <= limit,
      do: shrunk,
      else: shrink_tool_calls(calls, div(budget, 2), limit)
  end

  defp shrink_tool_calls(calls, _budget, _limit),
    do: [%{"truncated" => true, "bytes" => json_size(calls)}]

  defp put_arguments(%{"function" => %{"arguments" => old} = f} = call, args) when is_binary(old),
    do: Map.put(call, "function", Map.put(f, "arguments", args))

  defp put_arguments(call, _args), do: call

  defp mark_truncated(map, true), do: Map.put(map, "truncated", true)
  defp mark_truncated(map, false), do: map

  defp put_unless_nil(map, _key, nil), do: map
  defp put_unless_nil(map, key, value), do: Map.put(map, key, value)

  @doc """
  UTF-8-safe truncation that keeps the head and tail. Returns `{binary, truncated?}`. The result
  is always ≤ `limit` bytes.
  """
  @spec truncate_binary(binary(), non_neg_integer()) :: {binary(), boolean()}
  def truncate_binary(bin, limit) when is_binary(bin) and byte_size(bin) <= limit,
    do: {bin, false}

  def truncate_binary(bin, limit) when is_binary(bin) do
    marker = "\n…[truncated #{byte_size(bin) - limit} bytes]…\n"

    if byte_size(marker) > limit do
      # A cap too small for even the marker: keep only the head.
      {bin |> binary_part(0, limit) |> trim_trailing_partial(), true}
    else
      budget = limit - byte_size(marker)
      head_n = div(budget * 6, 10)
      tail_n = budget - head_n

      head = bin |> binary_part(0, head_n) |> trim_trailing_partial()
      tail = bin |> binary_part(byte_size(bin) - tail_n, tail_n) |> trim_leading_partial()

      {head <> marker <> tail, true}
    end
  end

  # Remove a cut-off multibyte character
  defp trim_trailing_partial(bin, tries \\ 3)
  defp trim_trailing_partial(bin, _tries) when byte_size(bin) == 0, do: bin

  defp trim_trailing_partial(bin, tries) do
    cond do
      String.valid?(bin) -> bin
      tries == 0 -> ""
      true -> bin |> binary_part(0, byte_size(bin) - 1) |> trim_trailing_partial(tries - 1)
    end
  end

  defp trim_leading_partial(<<b, rest::binary>>) when b >= 0x80 and b < 0xC0,
    do: trim_leading_partial(rest)

  defp trim_leading_partial(bin), do: bin
  # ---------------------------------------------------------------------------
  # misc

  defp cap_error_message(%{"error" => %{"message" => msg} = error} = gen)
       when is_binary(msg) and byte_size(msg) > @error_message_max do
    {msg, _} = truncate_binary(msg, @error_message_max)
    Map.put(gen, "error", Map.put(error, "message", msg))
  end

  defp cap_error_message(gen), do: gen

  defp hash_end_user(gen, %{hash_end_user: true}) do
    case Map.get(gen, "end_user_ref") do
      nil -> gen
      ref -> Map.put(gen, "end_user_ref", sha256_hex(to_string(ref)))
    end
  end

  defp hash_end_user(gen, _), do: gen

  defp redact(gen, %{log: %{redact: fun}}) when is_function(fun, 1) do
    case fun.(gen) do
      %{} = redacted ->
        redacted

      other ->
        Logger.warning("[PromptOn] redact hook returned #{inspect(other)}; dropping payload")
        drop_payload(gen)
    end
  rescue
    e ->
      Logger.warning("[PromptOn] redact hook raised #{Exception.message(e)}; dropping payload")
      drop_payload(gen)
  end

  defp redact(gen, _), do: gen

  @doc false
  def canonical_json(value) do
    case Jason.encode(value) do
      {:ok, json} -> json
      {:error, _} -> inspect(value, limit: :infinity, printable_limit: :infinity)
    end
  end

  @doc false
  def sha256_hex(bin), do: :crypto.hash(:sha256, bin) |> Base.encode16(case: :lower)

  defp json_size(value), do: byte_size(canonical_json(value))
end
