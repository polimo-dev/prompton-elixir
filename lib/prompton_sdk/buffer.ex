defmodule PromptOnSDK.Buffer do
  @moduledoc """
  Log batcher GenServer (§7.5, §9.2 failure matrix). Collects generation/feedback items and sends
  them with `POST /generations` / `POST /feedback`.

  * **The caller is never blocked**: `enqueue/2` is a cast. The cost of encoding and policy
    application is split between the caller (`PromptOnSDK.log/1`) and this process, and sending is
    done by tasks under `PromptOnSDK.TaskSupervisor` (at most 2 concurrently).
  * **Queue cap** `log.max_buffer` (10k). When exceeded, drop the **oldest first** +
    `[:prompton, :log, :dropped]`; the warning log is emitted at most once per minute.
  * **Flush**: whichever of 100 items / 1MB / 2 seconds comes first (`log.flush_size /
    flush_bytes / flush_interval`). One request is **≤200 items and ≤4MB encoded** (below the
    server parser cap of 5MB); when building a batch, cut at whichever limit is reached first.
    An item over 4MB is dropped at enqueue time + `[:prompton, :log, :dropped]` (reason
    `:too_large`).
  * **Failure**: 5xx, transport failure, task crash: put the batch back at the **front** of the
    queue and back off (1s → 2 → 4 … 60s cap + jitter ≤1s).
    `429` (and a 5xx carrying `Retry-After`, usually `503`): pause for `Retry-After` (seconds or
    HTTP-date), then retry.
    `413`: split the batch in half and resend both halves as they are (on another 413, halve
    again; a single item that gets 413 is dropped + `:too_large`).
    Other 4xx (auth failure etc.): drop without retry + log. `rejected` items in a `202` are only
    logged (partial acceptance).
  * **Drain**: `trap_exit` + `terminate/2` send the remaining items **synchronously** (at most 5
    seconds). Child spec `shutdown: 10_000`.
  * `flush/1` (synchronous) is for tests and manual drains.

  Queue entries are `{map, bytes}`; `bytes` is measured by JSON-encoding at enqueue time (an item
  that cannot be encoded is dropped on the spot + log).
  """

  use GenServer
  require Logger

  alias PromptOnSDK.Snapshot.Store
  alias PromptOnSDK.Telemetry

  @max_batch 200
  @max_batch_bytes 4_000_000
  @max_concurrency 2
  @backoff_min 1_000
  @backoff_cap 60_000
  @drain_timeout 5_000
  @warn_interval 60_000

  @type lane :: :generations | :feedback

  # `prebuilt`: pieces split after a 413. On the next send they go out before the queue, as they
  # are, without being re-merged.
  @empty_lane %{queue: :queue.new(), count: 0, bytes: 0, prebuilt: []}

  defstruct config: nil,
            lanes: %{generations: @empty_lane, feedback: @empty_lane},
            timer: nil,
            in_flight: %{},
            failures: 0,
            paused_until: nil,
            last_drop_warn: nil,
            drops_since_warn: 0

  # ---------------------------------------------------------------------------
  # public

  @doc false
  def child_spec(config) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [config]},
      shutdown: 10_000,
      type: :worker
    }
  end

  @doc false
  def start_link(config) do
    GenServer.start_link(__MODULE__, config, name: __MODULE__)
  end

  @doc "Enqueues an item (cast). `{:error, :not_running}` when the process is not running."
  @spec enqueue(lane(), map()) :: :ok | {:error, :not_running}
  def enqueue(lane, item) when lane in [:generations, :feedback] and is_map(item) do
    case Process.whereis(__MODULE__) do
      nil -> {:error, :not_running}
      pid -> GenServer.cast(pid, {:enqueue, lane, item})
    end
  end

  @doc "Sends the remaining items synchronously (at most `timeout` ms). Returns the count left."
  @spec flush(timeout()) :: {:ok, non_neg_integer()} | {:error, :not_running}
  def flush(timeout \\ @drain_timeout) do
    GenServer.call(__MODULE__, {:flush, timeout}, timeout + 1_000)
  catch
    :exit, {:noproc, _} -> {:error, :not_running}
  end

  @doc "State for tests and diagnostics."
  @spec stats() :: map()
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  # ---------------------------------------------------------------------------
  # callbacks

  @impl true
  def init(config) do
    Process.flag(:trap_exit, true)
    {:ok, %__MODULE__{config: config}}
  end

  @impl true
  def handle_cast({:enqueue, lane, item}, state) do
    case Jason.encode(item) do
      {:ok, json} when byte_size(json) > @max_batch_bytes ->
        Logger.warning(
          "[PromptOn] dropping #{lane} item #{inspect(item["id"])}: #{byte_size(json)} bytes exceeds the #{@max_batch_bytes}-byte request limit"
        )

        Telemetry.execute(Telemetry.log_dropped(), %{count: 1}, %{reason: :too_large, lane: lane})
        {:noreply, state}

      {:ok, json} ->
        state =
          state
          |> push(lane, {item, byte_size(json)})
          |> maybe_flush()

        {:noreply, state}

      {:error, reason} ->
        Logger.warning("[PromptOn] dropping unencodable #{lane} item: #{inspect(reason)}")
        Telemetry.execute(Telemetry.log_dropped(), %{count: 1}, %{reason: :encode, lane: lane})
        {:noreply, state}
    end
  end

  @impl true
  def handle_call({:flush, timeout}, _from, state) do
    state = drain(state, timeout)
    {:reply, {:ok, pending(state)}, state}
  end

  def handle_call(:stats, _from, state) do
    {:reply,
     %{
       generations: %{count: state.lanes.generations.count, bytes: state.lanes.generations.bytes},
       feedback: %{count: state.lanes.feedback.count, bytes: state.lanes.feedback.bytes},
       in_flight: map_size(state.in_flight),
       failures: state.failures,
       paused_until: state.paused_until
     }, state}
  end

  @impl true
  def handle_info(:flush, state) do
    {:noreply, maybe_flush(%{state | timer: nil}, :timer)}
  end

  def handle_info({ref, result}, state) when is_reference(ref) do
    case Map.pop(state.in_flight, ref) do
      {nil, _} ->
        {:noreply, state}

      {{lane, items, bytes, _task}, in_flight} ->
        Process.demonitor(ref, [:flush])
        state = %{state | in_flight: in_flight} |> handle_result(lane, items, bytes, result)
        {:noreply, maybe_flush(state)}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.in_flight, ref) do
      {nil, _} ->
        {:noreply, state}

      {{lane, items, bytes, _task}, in_flight} ->
        state =
          %{state | in_flight: in_flight}
          |> handle_result(lane, items, bytes, {:error, {:task_down, reason}})

        {:noreply, maybe_flush(state)}
    end
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}
  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    state = drain(state, @drain_timeout)

    case pending(state) do
      0 -> :ok
      n -> Logger.warning("[PromptOn] buffer terminated with #{n} unsent items")
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # queue ops

  defp push(state, lane_name, {_item, bytes} = entry) do
    lane = Map.fetch!(state.lanes, lane_name)
    max = state.config.log.max_buffer

    {lane, state} =
      if lane.count >= max do
        {lane, dropped} = drop_oldest(lane, lane.count - max + 1)
        {lane, note_drop(state, lane_name, dropped, :max_buffer)}
      else
        {lane, state}
      end

    lane = %{
      lane
      | queue: :queue.in(entry, lane.queue),
        count: lane.count + 1,
        bytes: lane.bytes + bytes
    }

    put_lane(state, lane_name, lane)
  end

  defp requeue_front(state, lane_name, items) do
    lane = Map.fetch!(state.lanes, lane_name)
    bytes = items |> Enum.map(&elem(&1, 1)) |> Enum.sum()

    lane = %{
      lane
      | queue: :queue.join(:queue.from_list(items), lane.queue),
        count: lane.count + length(items),
        bytes: lane.bytes + bytes
    }

    max = state.config.log.max_buffer

    if lane.count > max do
      {lane, dropped} = drop_oldest(lane, lane.count - max)
      state |> note_drop(lane_name, dropped, :max_buffer) |> put_lane(lane_name, lane)
    else
      put_lane(state, lane_name, lane)
    end
  end

  defp drop_oldest(lane, n) when n <= 0, do: {lane, 0}

  defp drop_oldest(lane, n) do
    Enum.reduce(1..n, {lane, 0}, fn _, {lane, dropped} ->
      case :queue.out(lane.queue) do
        {{:value, {_item, bytes}}, queue} ->
          {%{lane | queue: queue, count: lane.count - 1, bytes: lane.bytes - bytes}, dropped + 1}

        {:empty, _} ->
          {lane, dropped}
      end
    end)
  end

  # One request's worth: a prebuilt piece as a whole if there is one, otherwise up to max_count
  # items / max_bytes bytes from the queue.
  defp take(%{prebuilt: [entries | rest]} = lane, _max_count, _max_bytes) do
    bytes = entries |> Enum.map(&elem(&1, 1)) |> Enum.sum()

    {entries,
     %{lane | prebuilt: rest, count: lane.count - length(entries), bytes: lane.bytes - bytes}}
  end

  defp take(lane, max_count, max_bytes) do
    do_take(lane, max_count, max_bytes, 0, [])
  end

  defp do_take(lane, 0, _max_bytes, _acc_bytes, acc), do: {Enum.reverse(acc), lane}

  defp do_take(lane, n, max_bytes, acc_bytes, acc) do
    case :queue.peek(lane.queue) do
      # The first item always goes in (items over 4MB were already filtered out at enqueue)
      {:value, {_item, bytes} = entry} when acc == [] or acc_bytes + bytes <= max_bytes ->
        {_, queue} = :queue.out(lane.queue)
        lane = %{lane | queue: queue, count: lane.count - 1, bytes: lane.bytes - bytes}
        do_take(lane, n - 1, max_bytes, acc_bytes + bytes, [entry | acc])

      _ ->
        {Enum.reverse(acc), lane}
    end
  end

  defp prebuild_front(state, lane_name, batches) do
    lane = Map.fetch!(state.lanes, lane_name)
    entries = List.flatten(batches)
    bytes = entries |> Enum.map(&elem(&1, 1)) |> Enum.sum()

    put_lane(state, lane_name, %{
      lane
      | prebuilt: batches ++ lane.prebuilt,
        count: lane.count + length(entries),
        bytes: lane.bytes + bytes
    })
  end

  defp put_lane(state, name, lane), do: %{state | lanes: Map.put(state.lanes, name, lane)}

  defp pending(state), do: state.lanes.generations.count + state.lanes.feedback.count

  defp note_drop(state, _lane, 0, _reason), do: state

  defp note_drop(state, lane, dropped, reason) do
    Telemetry.execute(Telemetry.log_dropped(), %{count: dropped}, %{reason: reason, lane: lane})
    now = System.monotonic_time(:millisecond)
    total = state.drops_since_warn + dropped

    if is_nil(state.last_drop_warn) or now - state.last_drop_warn >= @warn_interval do
      Logger.warning(
        "[PromptOn] log buffer full — dropped #{total} oldest #{lane} item(s) (#{reason})"
      )

      %{state | last_drop_warn: now, drops_since_warn: 0}
    else
      %{state | drops_since_warn: total}
    end
  end

  # ---------------------------------------------------------------------------
  # flushing (async)

  defp maybe_flush(state, trigger \\ :enqueue) do
    now = System.monotonic_time(:millisecond)
    cfg = state.config.log

    cond do
      pending(state) == 0 ->
        state

      state.paused_until && state.paused_until > now ->
        schedule(state, state.paused_until - now)

      map_size(state.in_flight) >= @max_concurrency ->
        state

      trigger == :timer or threshold_reached?(state, cfg) ->
        state |> start_batches() |> maybe_reschedule()

      true ->
        schedule(state, cfg.flush_interval)
    end
  end

  defp threshold_reached?(state, cfg) do
    Enum.any?(state.lanes, fn {_name, lane} ->
      lane.count >= cfg.flush_size or lane.bytes >= cfg.flush_bytes or lane.prebuilt != []
    end)
  end

  defp maybe_reschedule(state) do
    if pending(state) > 0 and map_size(state.in_flight) < @max_concurrency do
      schedule(state, state.config.log.flush_interval)
    else
      state
    end
  end

  defp start_batches(state) do
    Enum.reduce([:generations, :feedback], state, fn lane_name, state ->
      start_lane_batches(state, lane_name)
    end)
  end

  defp start_lane_batches(state, lane_name) do
    lane = Map.fetch!(state.lanes, lane_name)

    if lane.count > 0 and map_size(state.in_flight) < @max_concurrency do
      {items, lane} = take(lane, batch_size(state), @max_batch_bytes)
      state = put_lane(state, lane_name, lane)
      state = spawn_send(state, lane_name, items)
      start_lane_batches(state, lane_name)
    else
      state
    end
  end

  defp batch_size(state), do: min(state.config.log.flush_size, @max_batch)

  defp spawn_send(state, lane_name, items) do
    config = state.config
    maps = Enum.map(items, &elem(&1, 0))
    bytes = items |> Enum.map(&elem(&1, 1)) |> Enum.sum()

    task =
      Task.Supervisor.async_nolink(PromptOnSDK.TaskSupervisor, fn ->
        send_batch(config, lane_name, maps)
      end)

    %{state | in_flight: Map.put(state.in_flight, task.ref, {lane_name, items, bytes, task})}
  end

  defp send_batch(config, :generations, maps), do: config.client.post_generations(config, maps)
  defp send_batch(config, :feedback, maps), do: config.client.post_feedback(config, maps)

  defp schedule(%{timer: nil} = state, ms) do
    %{state | timer: Process.send_after(self(), :flush, max(ms, 0))}
  end

  defp schedule(state, _ms), do: state

  # ---------------------------------------------------------------------------
  # results

  defp handle_result(state, lane, items, bytes, {:ok, %{status: status} = resp})
       when status in 200..299 do
    body = Map.get(resp, :body)
    body = if is_map(body), do: body, else: %{}
    rejected = List.wrap(body["rejected"])

    unless rejected == [] do
      Logger.warning(
        "[PromptOn] #{lane}: #{length(rejected)} item(s) rejected: #{inspect(rejected, limit: 5)}"
      )
    end

    Telemetry.execute(
      Telemetry.log_flush(),
      %{
        count: length(items),
        bytes: bytes,
        accepted: body["accepted"] || 0,
        duplicates: body["duplicates"] || 0,
        rejected: length(rejected)
      },
      %{lane: lane, status: status}
    )

    %{state | failures: 0, paused_until: nil}
  end

  defp handle_result(state, lane, items, _bytes, {:ok, %{status: 429} = resp}) do
    retry_ms = retry_after_ms(resp) || backoff_ms(state.failures + 1)
    Logger.warning("[PromptOn] #{lane}: rate limited (429), retrying in #{retry_ms}ms")

    Telemetry.execute(Telemetry.log_error(), %{count: length(items)}, %{
      lane: lane,
      reason: :rate_limited,
      status: 429,
      retry_in_ms: retry_ms
    })

    state
    |> requeue_front(lane, items)
    |> pause(retry_ms)
  end

  # 413: split the batch in half and resend as is. A single item that gets 413 is dropped.
  defp handle_result(state, lane, [_single] = items, bytes, {:ok, %{status: 413}}) do
    Logger.error(
      "[PromptOn] #{lane}: server rejected a single #{bytes}-byte item with 413, dropping it"
    )

    Telemetry.execute(Telemetry.log_error(), %{count: 1}, %{
      lane: lane,
      reason: :payload_too_large,
      status: 413,
      retry_in_ms: nil
    })

    Telemetry.execute(Telemetry.log_dropped(), %{count: length(items)}, %{
      reason: :too_large,
      lane: lane
    })

    state
  end

  defp handle_result(state, lane, items, bytes, {:ok, %{status: 413}}) do
    {first, second} = Enum.split(items, div(length(items), 2))

    Logger.warning(
      "[PromptOn] #{lane}: batch of #{length(items)} item(s) / #{bytes} bytes rejected with 413, splitting in half"
    )

    Telemetry.execute(Telemetry.log_error(), %{count: length(items)}, %{
      lane: lane,
      reason: :payload_too_large,
      status: 413,
      retry_in_ms: 0
    })

    prebuild_front(state, lane, [first, second])
  end

  defp handle_result(state, lane, items, _bytes, {:ok, %{status: status} = resp})
       when status in 400..499 do
    Logger.error(
      "[PromptOn] #{lane}: server rejected batch with #{status}, dropping #{length(items)} item(s): " <>
        inspect(Map.get(resp, :body), limit: 10)
    )

    Telemetry.execute(Telemetry.log_error(), %{count: length(items)}, %{
      lane: lane,
      reason: :http_4xx,
      status: status,
      retry_in_ms: nil
    })

    Telemetry.execute(Telemetry.log_dropped(), %{count: length(items)}, %{
      reason: :http_4xx,
      lane: lane
    })

    state
  end

  defp handle_result(state, lane, items, _bytes, result) do
    {reason, status, retry_after} =
      case result do
        {:ok, %{status: status} = resp} -> {:http_5xx, status, retry_after_ms(resp)}
        {:error, reason} -> {reason, nil, nil}
        other -> {{:unexpected, other}, nil, nil}
      end

    failures = state.failures + 1
    # When a 5xx (usually 503) carries Retry-After, wait that long, as for a 429.
    retry_ms = retry_after || backoff_ms(failures)

    Logger.warning(
      "[PromptOn] #{lane}: send failed (#{inspect(reason)}), retrying in #{retry_ms}ms"
    )

    Telemetry.execute(Telemetry.log_error(), %{count: length(items)}, %{
      lane: lane,
      reason: reason,
      status: status,
      retry_in_ms: retry_ms
    })

    %{state | failures: failures}
    |> requeue_front(lane, items)
    |> pause(retry_ms)
  end

  defp pause(state, ms) do
    %{state | paused_until: System.monotonic_time(:millisecond) + ms}
  end

  defp backoff_ms(failures) do
    base = min(@backoff_min * Integer.pow(2, min(failures - 1, 10)), @backoff_cap)
    base + :rand.uniform(1_000)
  end

  defp retry_after_ms(resp) do
    headers = Map.get(resp, :headers) || %{}

    case Map.get(headers, "retry-after") do
      nil -> nil
      value -> parse_retry_after(String.trim(value))
    end
  end

  defp parse_retry_after(value) do
    case Integer.parse(value) do
      {secs, ""} -> secs * 1_000
      _ -> retry_after_from_date(Store.parse_http_date(value))
    end
  end

  defp retry_after_from_date(nil), do: nil
  defp retry_after_from_date(dt), do: max(DateTime.diff(dt, DateTime.utc_now(), :millisecond), 0)

  # ---------------------------------------------------------------------------
  # synchronous drain (flush/1, terminate/2)

  defp drain(state, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    state = cancel_timer(state)
    state = await_in_flight(state, deadline)
    drain_lanes(state, deadline)
  end

  defp await_in_flight(state, deadline) do
    Enum.reduce(state.in_flight, %{state | in_flight: %{}}, fn {ref, {lane, items, bytes, task}},
                                                               state ->
      remaining = max(deadline - System.monotonic_time(:millisecond), 0)

      case Task.yield(task, remaining) || Task.shutdown(task, :brutal_kill) do
        {:ok, result} ->
          Process.demonitor(ref, [:flush])
          handle_result(state, lane, items, bytes, result)

        {:exit, reason} ->
          handle_result(state, lane, items, bytes, {:error, {:task_down, reason}})

        nil ->
          requeue_front(state, lane, items)
      end
    end)
  end

  defp drain_lanes(state, deadline) do
    Enum.reduce([:generations, :feedback], state, &drain_lane(&2, &1, deadline))
  end

  defp drain_lane(state, lane_name, deadline) do
    lane = Map.fetch!(state.lanes, lane_name)
    now = System.monotonic_time(:millisecond)

    cond do
      lane.count == 0 ->
        state

      now >= deadline ->
        state

      true ->
        {items, lane} = take(lane, batch_size(state), @max_batch_bytes)
        state = put_lane(state, lane_name, lane)
        maps = Enum.map(items, &elem(&1, 0))
        bytes = items |> Enum.map(&elem(&1, 1)) |> Enum.sum()

        result =
          try do
            send_batch(state.config, lane_name, maps)
          rescue
            e -> {:error, {:client_exception, e}}
          catch
            kind, value -> {:error, {:client_exit, kind, value}}
          end

        state = handle_result(state, lane_name, items, bytes, result)

        # A batch that came back after a failure is not resent within the same drain (respect
        # the backoff).
        if state.failures > 0 or state.paused_until,
          do: state,
          else: drain_lane(state, lane_name, deadline)
    end
  end

  defp cancel_timer(%{timer: nil} = state), do: state

  defp cancel_timer(%{timer: ref} = state) do
    Process.cancel_timer(ref)
    %{state | timer: nil}
  end
end
