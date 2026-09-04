defmodule PromptOnSDK.SnapshotTest do
  use PromptOnSDK.RuntimeCase, async: false

  alias PromptOnSDK.Snapshot

  @updated [:prompton, :snapshot, :updated]
  @stale [:prompton, :snapshot, :stale]
  @fetch_error [:prompton, :snapshot, :fetch_error]

  defp ok_200(body, etag \\ ~s("sha256-abc"), last_modified \\ "Mon, 18 Aug 2026 09:12:03 GMT") do
    {:ok, %{status: 200, body: body, etag: etag, last_modified: last_modified}}
  end

  defp snapshot_json(overrides \\ %{}) do
    Fixtures.snapshot() |> Map.merge(overrides) |> Jason.encode!()
  end

  describe "boot" do
    test "no snapshot anywhere → not_ready, and boot is not blocked by a slow fetch" do
      test_pid = self()

      FakeClient.set(:fetch_snapshot, fn _etag, _opts ->
        send(test_pid, :fetch_started)
        Process.sleep(300)
        {:error, :econnrefused}
      end)

      t0 = System.monotonic_time(:millisecond)
      start_sdk()

      assert System.monotonic_time(:millisecond) - t0 < 250,
             "start_link blocked on the remote fetch"

      assert PromptOnSDK.resolve("diary_generation") == {:error, :not_ready}
      assert PromptOnSDK.prompt_names("diary_generation") == {:error, :not_ready}
      assert %{source: :none, stale?: true} = PromptOnSDK.snapshot_info()
      assert_receive :fetch_started, 500
    end

    test "loads disk cache with sidecar (source :disk) then promotes to :remote on 304" do
      attach_telemetry([@updated, @stale, @fetch_error])
      path = tmp_path("cache.json")

      write_snapshot_file(path, Fixtures.snapshot(), %{
        "etag" => ~s("e1"),
        "last_modified" => "Mon, 18 Aug 2026 09:12:03 GMT"
      })

      FakeClient.set(:fetch_snapshot, fn ~s("e1"), _opts -> {:ok, %{status: 304}} end)
      start_sdk(disk_cache: path)

      # Loaded synchronously in init, so resolve works immediately
      assert {:ok, r} = PromptOnSDK.resolve("diary_generation", %{language: "ko", plan: "pro"})
      assert r.source in [:disk, :remote]
      assert r.etag == ~s("e1")

      eventually(fn -> PromptOnSDK.snapshot_info().source == :remote end)
      info = PromptOnSDK.snapshot_info()
      assert info.stale? == false
      assert info.etag == ~s("e1")
      assert info.last_modified == "Mon, 18 Aug 2026 09:12:03 GMT"
      assert is_integer(info.age_seconds)

      assert [{:fetch_snapshot, ~s("e1"), [receive_timeout: 3_000]}] =
               FakeClient.calls(:fetch_snapshot)

      refute_receive {:telemetry, @updated, _, _}
    end

    test "falls back to bundle when disk cache is missing; failure keeps :bundle and emits stale" do
      attach_telemetry([@updated, @stale, @fetch_error])
      bundle = tmp_path("bundle.json")

      write_snapshot_file(bundle, Fixtures.snapshot(), %{
        "etag" => ~s("b1"),
        "last_modified" => "Mon, 18 Aug 2026 09:12:03 GMT"
      })

      FakeClient.set(:fetch_snapshot, fn _etag, _opts -> {:error, :timeout} end)

      start_sdk(disk_cache: tmp_path("missing.json"), bundle: {:file, bundle})

      assert {:ok, %{source: :bundle}} = PromptOnSDK.resolve("diary_generation")
      assert_receive {:telemetry, @fetch_error, _, %{reason: :timeout, attempt: 1}}, 500
      assert_receive {:telemetry, @stale, %{age_seconds: age}, %{source: :bundle}}, 500
      assert is_integer(age) and age >= 0
      assert %{source: :bundle, stale?: true} = PromptOnSDK.snapshot_info()
    end

    test "rejects disk/bundle snapshot whose environment does not match the configured one" do
      path = tmp_path("staging.json")

      write_snapshot_file(path, Map.put(Fixtures.snapshot(), "environment", "staging"), %{
        "etag" => ~s("s1")
      })

      FakeClient.set(:fetch_snapshot, fn _etag, _opts -> {:error, :nxdomain} end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          start_sdk(disk_cache: path, api_key: "ptn_heydiary_xyz")
          assert PromptOnSDK.resolve("diary_generation") == {:error, :not_ready}
        end)

      assert log =~
               "environment \"staging\" does not match the configured environment \"production\""
    end

    test "a staging app loads a staging snapshot (the environment is configured, not derived)" do
      path = tmp_path("staging.json")

      write_snapshot_file(path, Map.put(Fixtures.snapshot(), "environment", "staging"), %{
        "etag" => ~s("s1")
      })

      start_sdk(mode: :offline, api_key: nil, environment: "staging", disk_cache: path)
      assert {:ok, %{source: :disk}} = PromptOnSDK.resolve("diary_generation")
      assert FakeClient.calls() == []
      assert PromptOnSDK.refresh() == :ok
    end

    test "corrupt disk cache is skipped in favour of the bundle" do
      bad = tmp_path("bad.json")
      File.write!(bad, "{not json")
      bundle = tmp_path("bundle.json")
      write_snapshot_file(bundle, Fixtures.snapshot())

      start_sdk(mode: :offline, disk_cache: bad, bundle: {:file, bundle})
      assert {:ok, %{source: :bundle}} = PromptOnSDK.resolve("diary_generation")
    end
  end

  describe "remote fetch" do
    test "200 → persistent_term replaced, disk cache + sidecar written, updated telemetry" do
      attach_telemetry([@updated])
      path = tmp_path("cache.json")
      body = snapshot_json()

      FakeClient.set(:fetch_snapshot, fn nil, _opts ->
        ok_200(body, ~s("e2"), "Tue, 19 Aug 2026 00:00:00 GMT")
      end)

      start_sdk(disk_cache: path)

      assert_receive {:telemetry, @updated, %{},
                      %{etag: ~s("e2"), source: :remote, environment: "production"}},
                     500

      assert {:ok, %{source: :remote, etag: ~s("e2")}} =
               PromptOnSDK.resolve("diary_generation")

      assert File.read!(path) == body
      meta = Jason.decode!(File.read!(path <> ".meta.json"))
      assert meta["etag"] == ~s("e2")
      assert meta["last_modified"] == "Tue, 19 Aug 2026 00:00:00 GMT"
      assert meta["environment"] == "production"
      assert {:ok, _, _} = DateTime.from_iso8601(meta["fetched_at"])
      refute File.exists?(path <> ".tmp")

      info = PromptOnSDK.snapshot_info()
      assert info.source == :remote and info.stale? == false and info.etag == ~s("e2")
    end

    test "polling sends If-None-Match; 304 leaves snapshot unchanged" do
      body = snapshot_json()
      test_pid = self()

      FakeClient.set(:fetch_snapshot, fn
        nil, _ ->
          ok_200(body, ~s("e3"))

        ~s("e3"), _ ->
          send(test_pid, :polled_304)
          {:ok, %{status: 304}}
      end)

      start_sdk(poll_interval: 30)
      assert_receive :polled_304, 500
      assert_receive :polled_304, 500
      assert %{etag: ~s("e3"), source: :remote, stale?: false} = PromptOnSDK.snapshot_info()
    end

    test "failure after success marks stale (keeps old snapshot) and backs off; recovery clears stale" do
      attach_telemetry([@stale, @fetch_error, @updated])
      body = snapshot_json()
      {:ok, agent} = Agent.start_link(fn -> :ok end)

      FakeClient.set(:fetch_snapshot, fn etag, _ ->
        case {Agent.get(agent, & &1), etag} do
          {:ok, nil} -> ok_200(body, ~s("e4"))
          {:fail, _} -> {:ok, %{status: 503, body: "down"}}
          {:ok, _} -> {:ok, %{status: 304}}
        end
      end)

      start_sdk(poll_interval: 30)
      assert_receive {:telemetry, @updated, _, _}, 500

      Agent.update(agent, fn _ -> :fail end)

      assert_receive {:telemetry, @fetch_error, _,
                      %{reason: {:http, 503, "down"}, attempt: 1, next_retry_ms: 30}},
                     500

      assert_receive {:telemetry, @stale, %{age_seconds: _}, %{source: :remote}}, 500
      assert {:ok, %{source: :remote}} = PromptOnSDK.resolve("diary_generation")
      assert %{stale?: true} = PromptOnSDK.snapshot_info()

      # The second failure doubles the backoff
      assert_receive {:telemetry, @fetch_error, _, %{attempt: 2, next_retry_ms: 60}}, 500

      Agent.update(agent, fn _ -> :ok end)
      eventually(fn -> PromptOnSDK.snapshot_info().stale? == false end, 1_500)
    end

    test "invalid body is a fetch error, snapshot not replaced" do
      attach_telemetry([@fetch_error])
      FakeClient.set(:fetch_snapshot, fn _, _ -> ok_200(~s({"schema_version": "x"})) end)
      start_sdk()

      assert_receive {:telemetry, @fetch_error, _, %{reason: {:decode, {:invalid_snapshot, _}}}},
                     500

      assert PromptOnSDK.resolve("diary_generation") == {:error, :not_ready}
    end

    test "client exceptions are contained" do
      attach_telemetry([@fetch_error])
      FakeClient.set(:fetch_snapshot, fn _, _ -> raise "kaboom" end)
      start_sdk()

      assert_receive {:telemetry, @fetch_error, _,
                      %{reason: {:client_exception, %RuntimeError{}}}},
                     500

      assert Process.alive?(Process.whereis(Snapshot))
    end

    test "refresh/0 fetches synchronously" do
      body = snapshot_json()
      FakeClient.set(:fetch_snapshot, fn _, _ -> {:error, :econnrefused} end)
      start_sdk()
      eventually(fn -> FakeClient.calls(:fetch_snapshot) != [] end)
      assert PromptOnSDK.resolve("diary_generation") == {:error, :not_ready}

      FakeClient.set(:fetch_snapshot, fn _, _ -> ok_200(body, ~s("e5")) end)
      assert PromptOnSDK.refresh() == :ok
      assert {:ok, %{etag: ~s("e5")}} = PromptOnSDK.resolve("diary_generation")

      FakeClient.set(:fetch_snapshot, fn _, _ -> {:error, :boom} end)
      assert PromptOnSDK.refresh() == {:error, :boom}
    end

    test "map bodies are accepted and re-encoded for disk" do
      path = tmp_path("cache.json")
      FakeClient.set(:fetch_snapshot, fn _, _ -> ok_200(Fixtures.snapshot(), ~s("e6")) end)
      start_sdk(disk_cache: path)
      eventually(fn -> File.exists?(path) end)
      assert {:ok, _, _} = PromptOnSDK.SnapshotData.decode_json(File.read!(path))
    end
  end

  describe "modes" do
    test ":test mode never touches the client and refresh is a no-op" do
      start_sdk(mode: :test)
      Process.sleep(50)
      assert FakeClient.calls() == []
      assert PromptOnSDK.refresh() == :ok
      assert PromptOnSDK.resolve("x", %{}) == {:error, :not_ready}
    end

    test "live without api_key/base_url runs on local snapshot only" do
      bundle = tmp_path("bundle.json")
      write_snapshot_file(bundle, Fixtures.snapshot())
      start_sdk(api_key: nil, base_url: nil, bundle: {:file, bundle})
      Process.sleep(30)
      assert FakeClient.calls() == []
      assert {:ok, %{source: :bundle}} = PromptOnSDK.resolve("diary_generation")
      assert PromptOnSDK.refresh() == {:error, :remote_disabled}
    end
  end

  test "Store.parse_http_date" do
    assert %DateTime{year: 2026, month: 8, day: 18, hour: 9, minute: 12, second: 3} =
             Store.parse_http_date("Mon, 18 Aug 2026 09:12:03 GMT")

    assert %DateTime{} = Store.parse_http_date("2026-08-18T09:12:03Z")
    assert Store.parse_http_date("garbage") == nil
    assert Store.parse_http_date(nil) == nil
  end
end
