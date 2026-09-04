defmodule PromptOnSDK.BufferTest do
  use PromptOnSDK.RuntimeCase, async: false

  alias PromptOnSDK.Buffer

  @flush [:prompton, :log, :flush]
  @dropped [:prompton, :log, :dropped]
  @error [:prompton, :log, :error]

  defp gen(i),
    do: %{
      "id" => "gen-#{i}",
      "use_case" => "diary_generation",
      "status" => "ok",
      "started_at" => "2026-08-18T00:00:00Z"
    }

  # Starts only the Buffer (no snapshot poller): Config + TaskSupervisor + Buffer, no Supervisor.
  defp start_buffer(opts \\ []) do
    log =
      Keyword.merge(
        [flush_interval: 50, flush_size: 100, flush_bytes: 1_000_000, max_buffer: 10_000],
        opts
      )

    config = PromptOnSDK.Config.load(Keyword.merge(default_opts(), log: log))
    PromptOnSDK.Config.put(config)
    start_supervised!({Task.Supervisor, name: PromptOnSDK.TaskSupervisor})
    start_supervised!({Buffer, config})
    config
  end

  defp collect_batches(acc \\ []) do
    receive do
      {:fake_client, :post_generations, [items]} -> collect_batches([items | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "flushes by size (flush_size) in batches ≤ 200 and emits flush telemetry" do
    attach_telemetry([@flush])
    FakeClient.notify(self())
    FakeClient.set(:post_generations, fn items -> ok_202(length(items)) end)
    start_buffer(flush_size: 5, flush_interval: 60_000)

    for i <- 1..5, do: assert(:ok = Buffer.enqueue(:generations, gen(i)))

    assert_receive {:fake_client, :post_generations, [items]}, 500
    assert Enum.map(items, & &1["id"]) == Enum.map(1..5, &"gen-#{&1}")

    assert_receive {:telemetry, @flush, %{count: 5, accepted: 5, rejected: 0},
                    %{lane: :generations, status: 202}},
                   500

    eventually(fn -> Buffer.stats().generations.count == 0 end)
  end

  test "flushes by time (flush_interval) when below size threshold" do
    FakeClient.notify(self())
    FakeClient.set(:post_generations, fn _ -> ok_202() end)
    start_buffer(flush_interval: 30, flush_size: 100)

    Buffer.enqueue(:generations, gen(1))
    refute_receive {:fake_client, :post_generations, _}, 10
    assert_receive {:fake_client, :post_generations, [[%{"id" => "gen-1"}]]}, 500
  end

  test "flushes by bytes (flush_bytes)" do
    FakeClient.notify(self())
    FakeClient.set(:post_generations, fn _ -> ok_202() end)
    start_buffer(flush_bytes: 300, flush_interval: 60_000)

    Buffer.enqueue(:generations, gen(1))
    refute_receive {:fake_client, :post_generations, _}, 10
    Buffer.enqueue(:generations, Map.put(gen(2), "pad", String.duplicate("x", 300)))
    assert_receive {:fake_client, :post_generations, [[_, _]]}, 500
  end

  test "batches are capped at 200 per request even if flush_size is larger" do
    FakeClient.notify(self())
    FakeClient.set(:post_generations, fn _ -> ok_202() end)
    start_buffer(flush_size: 500, flush_interval: 20)

    for i <- 1..250, do: Buffer.enqueue(:generations, gen(i))
    assert_receive {:fake_client, :post_generations, [batch1]}, 500
    assert_receive {:fake_client, :post_generations, [batch2]}, 500
    assert length(batch1) == 200 and length(batch2) == 50
  end

  test "batches are also capped at 4MB encoded, splitting when items would exceed it" do
    FakeClient.notify(self())
    FakeClient.set(:post_generations, fn _ -> ok_202() end)
    start_buffer(flush_size: 3, flush_bytes: 100_000_000, flush_interval: 60_000)

    big = String.duplicate("x", 1_500_000)
    for i <- 1..3, do: Buffer.enqueue(:generations, Map.put(gen(i), "pad", big))

    assert_receive {:fake_client, :post_generations, [batch1]}, 2_000
    assert_receive {:fake_client, :post_generations, [batch2]}, 2_000
    assert Enum.map(batch1, & &1["id"]) == ["gen-1", "gen-2"]
    assert Enum.map(batch2, & &1["id"]) == ["gen-3"]
    assert byte_size(Jason.encode!(batch1)) <= 4_000_000
  end

  test "a single item over 4MB is dropped at enqueue with reason :too_large" do
    attach_telemetry([@dropped])
    FakeClient.notify(self())
    FakeClient.set(:post_generations, fn _ -> ok_202() end)
    start_buffer(flush_size: 1, flush_interval: 60_000)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        Buffer.enqueue(:generations, Map.put(gen(1), "pad", String.duplicate("x", 4_100_000)))

        assert_receive {:telemetry, @dropped, %{count: 1},
                        %{reason: :too_large, lane: :generations}},
                       2_000
      end)

    assert log =~ "exceeds the 4000000-byte request limit"
    assert Buffer.stats().generations.count == 0
    refute_receive {:fake_client, :post_generations, _}, 50
  end

  test "413 splits the batch in half and resends the halves as-is; a lone 413 item is dropped" do
    attach_telemetry([@error, @dropped, @flush])
    FakeClient.notify(self())

    # Any batch containing gen-3 gets a 413 (the item itself is too large); everything else 202
    FakeClient.set(:post_generations, fn items ->
      if Enum.any?(items, &(&1["id"] == "gen-3")),
        do: {:ok, %{status: 413, body: %{"error" => %{"code" => "too_large"}}, headers: %{}}},
        else: ok_202(length(items))
    end)

    start_buffer(flush_size: 4, flush_interval: 60_000)
    for i <- 1..4, do: Buffer.enqueue(:generations, gen(i))

    assert_receive {:fake_client, :post_generations, [[_, _, _, _]]}, 500

    assert_receive {:telemetry, @error, %{count: 4},
                    %{reason: :payload_too_large, status: 413, retry_in_ms: 0}},
                   500

    # The two halves go out in order, without being merged back together
    assert_receive {:fake_client, :post_generations, [[%{"id" => "gen-1"}, %{"id" => "gen-2"}]]},
                   500

    assert_receive {:fake_client, :post_generations, [[%{"id" => "gen-3"}, %{"id" => "gen-4"}]]},
                   500

    assert_receive {:telemetry, @flush, %{count: 2, accepted: 2}, _}, 500

    # The second half is also 413, so it is halved again: gen-3 alone gets 413 and is dropped,
    # gen-4 succeeds
    assert_receive {:fake_client, :post_generations, [[%{"id" => "gen-3"}]]}, 500
    assert_receive {:fake_client, :post_generations, [[%{"id" => "gen-4"}]]}, 500

    assert_receive {:telemetry, @dropped, %{count: 1}, %{reason: :too_large, lane: :generations}},
                   500

    assert_receive {:telemetry, @flush, %{count: 1, accepted: 1}, _}, 500

    eventually(fn -> Buffer.stats().generations.count == 0 end)
    assert Buffer.stats().failures == 0
    refute_receive {:fake_client, :post_generations, _}, 50
  end

  test "413 halves are resent during a synchronous drain too" do
    FakeClient.notify(self())

    FakeClient.set(:post_generations, fn items ->
      if length(items) > 1,
        do: {:ok, %{status: 413, body: "", headers: %{}}},
        else: ok_202(1)
    end)

    start_buffer(flush_size: 100, flush_interval: 60_000)
    for i <- 1..4, do: Buffer.enqueue(:generations, gen(i))
    _ = Buffer.stats()

    assert {:ok, 0} = Buffer.flush()
    batches = collect_batches() |> Enum.map(fn b -> Enum.map(b, & &1["id"]) end)

    assert batches == [
             ["gen-1", "gen-2", "gen-3", "gen-4"],
             ["gen-1", "gen-2"],
             ["gen-1"],
             ["gen-2"],
             ["gen-3", "gen-4"],
             ["gen-3"],
             ["gen-4"]
           ]
  end

  test "503 with Retry-After waits that long (like 429); without it, backoff" do
    attach_telemetry([@error])
    FakeClient.notify(self())

    FakeClient.set(:post_generations, fn _ ->
      {:ok,
       %{
         status: 503,
         body: %{"error" => %{"code" => "unavailable"}},
         headers: %{"retry-after" => "5"}
       }}
    end)

    start_buffer(flush_size: 1, flush_interval: 60_000)
    Buffer.enqueue(:generations, gen(1))

    assert_receive {:telemetry, @error, %{count: 1},
                    %{reason: :http_5xx, status: 503, retry_in_ms: 5_000}},
                   500

    eventually(fn -> Buffer.stats().generations.count == 1 end)
    assert Buffer.stats().paused_until != nil
    assert Buffer.stats().failures == 1
  end

  test "5xx requeues at the front with backoff, then succeeds preserving order" do
    attach_telemetry([@error, @flush])
    FakeClient.notify(self())
    {:ok, agent} = Agent.start_link(fn -> :fail end)

    FakeClient.set(:post_generations, fn _ ->
      case Agent.get(agent, & &1) do
        :fail -> {:ok, %{status: 503, body: "down", headers: %{}}}
        :ok -> ok_202()
      end
    end)

    start_buffer(flush_size: 2, flush_interval: 60_000)
    Buffer.enqueue(:generations, gen(1))
    Buffer.enqueue(:generations, gen(2))

    assert_receive {:fake_client, :post_generations, [[%{"id" => "gen-1"}, %{"id" => "gen-2"}]]},
                   500

    assert_receive {:telemetry, @error, %{count: 2},
                    %{reason: :http_5xx, status: 503, retry_in_ms: retry}},
                   500

    assert retry >= 1_000 and retry <= 2_000
    eventually(fn -> Buffer.stats().generations.count == 2 end)
    Buffer.enqueue(:generations, gen(3))
    # Nothing is resent while backing off
    refute_receive {:fake_client, :post_generations, _}, 100

    Agent.update(agent, fn _ -> :ok end)

    # A synchronous flush drains without waiting out the backoff; the requeued batch must be first
    assert {:ok, 0} = Buffer.flush()
    assert [[%{"id" => "gen-1"}, %{"id" => "gen-2"}], [%{"id" => "gen-3"}]] = collect_batches()
    assert %{failures: 0} = Buffer.stats()
  end

  test "transport errors and task crashes are retried like 5xx" do
    attach_telemetry([@error])
    FakeClient.notify(self())

    FakeClient.set(:post_generations, fn _ ->
      {:error, %Mint.TransportError{reason: :econnrefused}}
    end)

    start_buffer(flush_size: 1, flush_interval: 60_000)

    Buffer.enqueue(:generations, gen(1))
    assert_receive {:telemetry, @error, _, %{reason: %Mint.TransportError{}}}, 500
    eventually(fn -> Buffer.stats().generations.count == 1 end)

    FakeClient.set(:post_generations, fn _ -> raise "task boom" end)
    start_supervised!({Task.Supervisor, name: :unused})
    Buffer.enqueue(:generations, gen(2))
    # Backoff is active, so force it with flush
    Buffer.flush(200)
    assert_receive {:telemetry, @error, _, %{reason: {:client_exception, _}}}, 500
    assert Buffer.stats().generations.count == 2
  end

  test "4xx (other than 429) drops the batch with error + dropped telemetry" do
    attach_telemetry([@error, @dropped])
    FakeClient.notify(self())

    FakeClient.set(:post_generations, fn _ ->
      {:ok, %{status: 401, body: %{"error" => "unauthorized"}, headers: %{}}}
    end)

    start_buffer(flush_size: 1, flush_interval: 60_000)

    Buffer.enqueue(:generations, gen(1))
    assert_receive {:telemetry, @error, %{count: 1}, %{reason: :http_4xx, status: 401}}, 500

    assert_receive {:telemetry, @dropped, %{count: 1}, %{reason: :http_4xx, lane: :generations}},
                   500

    eventually(fn -> Buffer.stats().generations.count == 0 end)
    assert Buffer.stats().failures == 0
  end

  test "429 honours Retry-After and requeues" do
    attach_telemetry([@error])
    FakeClient.notify(self())

    FakeClient.set(:post_generations, fn _ ->
      {:ok, %{status: 429, body: "", headers: %{"retry-after" => "7"}}}
    end)

    start_buffer(flush_size: 1, flush_interval: 60_000)

    Buffer.enqueue(:generations, gen(1))

    assert_receive {:telemetry, @error, %{count: 1},
                    %{reason: :rate_limited, status: 429, retry_in_ms: 7_000}},
                   500

    eventually(fn -> Buffer.stats().generations.count == 1 end)
    assert Buffer.stats().paused_until != nil
  end

  test "partial acceptance: rejected entries are logged only" do
    attach_telemetry([@flush])
    FakeClient.notify(self())

    FakeClient.set(:post_generations, fn items ->
      {:ok,
       %{
         status: 202,
         body: %{
           "accepted" => length(items) - 1,
           "duplicates" => 0,
           "rejected" => [%{"index" => 0, "id" => "gen-1", "code" => "invalid_request"}]
         },
         headers: %{}
       }}
    end)

    start_buffer(flush_size: 2, flush_interval: 60_000)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        Buffer.enqueue(:generations, gen(1))
        Buffer.enqueue(:generations, gen(2))
        assert_receive {:telemetry, @flush, %{count: 2, accepted: 1, rejected: 1}, _}, 500
      end)

    assert log =~ "1 item(s) rejected"
    assert Buffer.stats().generations.count == 0
  end

  test "max_buffer drops the oldest items with dropped telemetry and a rate-limited warning" do
    attach_telemetry([@dropped])
    FakeClient.set(:post_generations, fn _ -> ok_202() end)
    start_buffer(max_buffer: 3, flush_size: 100, flush_interval: 60_000)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        for i <- 1..5, do: Buffer.enqueue(:generations, gen(i))
        assert_receive {:telemetry, @dropped, %{count: 1}, %{reason: :max_buffer}}, 500
        assert_receive {:telemetry, @dropped, %{count: 1}, %{reason: :max_buffer}}, 500
        eventually(fn -> Buffer.stats().generations.count == 3 end)
      end)

    assert length(Regex.scan(~r/log buffer full/, log)) == 1

    FakeClient.notify(self())
    assert {:ok, 0} = Buffer.flush()
    assert [[%{"id" => "gen-3"}, %{"id" => "gen-4"}, %{"id" => "gen-5"}]] = collect_batches()
  end

  test "unencodable items are dropped without crashing" do
    attach_telemetry([@dropped])
    start_buffer()
    Buffer.enqueue(:generations, %{"bad" => make_ref()})
    assert_receive {:telemetry, @dropped, %{count: 1}, %{reason: :encode}}, 500
    assert Buffer.stats().generations.count == 0
  end

  test "terminate drains synchronously" do
    FakeClient.notify(self())
    FakeClient.set(:post_generations, fn _ -> ok_202() end)
    FakeClient.set(:post_feedback, fn _ -> ok_202() end)
    start_buffer(flush_size: 100, flush_interval: 60_000)

    for i <- 1..3, do: Buffer.enqueue(:generations, gen(i))
    Buffer.enqueue(:feedback, %{"generation_id" => "gen-1", "kind" => "thumbs", "value" => 1})
    # Guarantees the enqueues have been processed
    _ = Buffer.stats()

    :ok = stop_supervised!(Buffer)
    assert_received {:fake_client, :post_generations, [[_, _, _]]}
    assert_received {:fake_client, :post_feedback, [[%{"kind" => "thumbs"}]]}
  end

  test "feedback lane posts to /feedback" do
    FakeClient.notify(self())
    FakeClient.set(:post_feedback, fn _ -> ok_202() end)
    start_buffer(flush_size: 1, flush_interval: 60_000)
    Buffer.enqueue(:feedback, %{"generation_id" => "g", "kind" => "rating", "value" => 5})
    assert_receive {:fake_client, :post_feedback, [[%{"kind" => "rating"}]]}, 500
    refute_receive {:fake_client, :post_generations, _}, 20
  end

  test "enqueue without a running buffer returns {:error, :not_running}" do
    assert Buffer.enqueue(:generations, gen(1)) == {:error, :not_running}
    assert Buffer.flush() == {:error, :not_running}
  end
end
