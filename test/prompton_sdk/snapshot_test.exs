defmodule PromptOnSDK.SnapshotTest do
  use PromptOnSDK.RuntimeCase, async: false

  alias PromptOnSDK.Snapshot

  defmodule LegacyOnlyClient do
    @behaviour PromptOnSDK.Client

    @impl true
    def fetch_prompts(_config, _etag, _opts), do: raise("bulk fetch must not be used")

    @impl true
    def post_logs(_config, _items), do: {:error, :not_used}

    @impl true
    def post_feedback(_config, _items), do: {:error, :not_used}

    @impl true
    def post_events(_config, _items), do: {:error, :not_used}
  end

  @updated [:prompton, :prompt_document, :updated]
  @stale [:prompton, :prompt_document, :stale]
  @fetch_error [:prompton, :prompt_document, :fetch_error]

  defp ok_200(body, etag, last_modified \\ "Mon, 18 Aug 2026 09:12:03 GMT") do
    {:ok, %{status: 200, body: body, etag: etag, last_modified: last_modified}}
  end

  defp snapshot_json(overrides \\ %{}) do
    Fixtures.snapshot() |> Map.merge(overrides) |> Jason.encode!()
  end

  defp snapshot_json_for(key, overrides \\ %{}) do
    snapshot = Fixtures.snapshot()

    snapshot
    |> Map.merge(%{
      "prompts" => Map.take(snapshot["prompts"], [key]),
      "deployments" => Map.take(snapshot["deployments"], [key])
    })
    |> Map.merge(overrides)
    |> Jason.encode!()
  end

  defp shared_model_json(key, model_name) do
    Jason.encode!(%{
      "schema_version" => 7,
      "project" => "heydiary",
      "environment" => "production",
      "prompts" => %{
        key => %{
          "id" => "prompt-#{key}",
          "kind" => "chat",
          "input_schema" => [],
          "default_params" => %{},
          "payload_policy" => nil
        }
      },
      "deployments" => %{
        key => %{
          "id" => "deployment-#{key}",
          "revision" => "v2026.09.30-1",
          "model_id" => "shared-model",
          "params" => %{},
          "provider_options" => %{},
          "template_pins" => %{"default" => "version-#{key}"}
        }
      },
      "prompt_versions" => %{
        "version-#{key}" => %{
          "id" => "version-#{key}",
          "number" => 1,
          "kind" => "chat",
          "engine" => "liquid",
          "messages" => [%{"role" => "user", "content" => key}]
        }
      },
      "models" => %{
        "shared-model" => %{
          "id" => "shared-model",
          "provider" => "openrouter",
          "model_id" => model_name
        }
      }
    })
  end

  defp large_snapshot_json(extra_versions) do
    snapshot = Fixtures.snapshot()

    versions =
      Enum.reduce(1..extra_versions, snapshot["prompt_versions"], fn index, acc ->
        Map.put(acc, "deadline-junk-#{index}", %{
          "id" => "deadline-junk-#{index}",
          "number" => index,
          "kind" => "chat",
          "engine" => "liquid",
          "messages" => [
            %{"role" => "user", "content" => String.duplicate("deadline payload", 4)}
          ]
        })
      end)

    snapshot
    |> Map.put("prompt_versions", versions)
    |> Jason.encode!()
  end

  defp decision_snapshot_json(request_path \\ "/api/v1/systemone") do
    Jason.encode!(%{
      "schema_version" => 6,
      "environment" => "production",
      "prompts" => %{"route" => %{"id" => "p", "kind" => "decision"}},
      "deployments" => %{
        "route" => %{
          "id" => "d",
          "model_id" => "m",
          "revision" => "v2026.09.30-2",
          "api" => "decisions",
          "request_path" => request_path,
          "template_pins" => %{"default" => "v"}
        }
      },
      "prompt_versions" => %{
        "v" => %{
          "id" => "v",
          "kind" => "decision",
          "number" => 3,
          "engine" => "liquid",
          "decision" => %{
            "state" => %{"message" => "{{ input }}"},
            "questions" => %{
              "route" => %{
                "type" => "choice",
                "instructions" => "Route {{ team }}",
                "criteria" => %{"support" => nil}
              }
            }
          }
        }
      },
      "models" => %{
        "m" => %{"id" => "m", "provider" => "openrouter", "model_id" => "typesafe/jev-1.13"}
      }
    })
  end

  defp age_key(key, by_ms) do
    :sys.replace_state(Snapshot, fn state ->
      %{state | cache: Map.update(state.cache, key, %{}, &age_entry(&1, by_ms))}
    end)
  end

  defp age_entry(entry, by_ms) do
    entry
    |> Map.update(:last_attempt_ms, nil, &age_ms(&1, by_ms))
    |> Map.update(:last_success_ms, nil, &age_ms(&1, by_ms))
  end

  defp age_ms(nil, _by_ms), do: nil
  defp age_ms(value, by_ms), do: value - by_ms

  defp wait_until(fun, timeout \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    wait_until(fun, deadline, timeout)
  end

  defp wait_until(fun, deadline, timeout) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("condition did not become true within #{timeout}ms")

      true ->
        Process.sleep(10)
        wait_until(fun, deadline, timeout)
    end
  end

  describe "startup and local fallback" do
    test "startup and idle periods do not fetch remotely" do
      FakeClient.set(:fetch_prompt, fn _key, _etag, _opts ->
        flunk("startup must not fetch remote prompt config")
      end)

      start_sdk()
      Process.sleep(50)

      assert FakeClient.calls() == []

      assert PromptOnSDK.prompt_document_info() == %{
               etag: nil,
               last_modified: nil,
               source: :none,
               fetched_at: nil,
               stale?: true,
               age_seconds: nil
             }
    end

    test "loads disk cache synchronously but first prompt use still validates that key" do
      attach_telemetry([@updated])
      path = tmp_path("cache.json")

      write_snapshot_file(path, Fixtures.snapshot(), %{
        "etag" => ~s("disk-e1"),
        "last_modified" => "Mon, 18 Aug 2026 09:12:03 GMT"
      })

      FakeClient.set(:fetch_prompt, fn "diary_generation", ~s("disk-e1"), opts ->
        assert opts[:receive_timeout] == 1_000
        assert opts[:retry] == false
        ok_200(snapshot_json(), ~s("remote-e1"))
      end)

      start_sdk(disk_cache: path)
      assert FakeClient.calls() == []

      assert {:ok, %{source: :remote, etag: ~s("remote-e1")}} =
               PromptOnSDK.prompt("diary_generation")

      assert_receive {:telemetry, @updated, %{},
                      %{etag: ~s("remote-e1"), source: :remote, prompt_key: "diary_generation"}},
                     500

      assert [{:fetch_prompt, "diary_generation", ~s("disk-e1"), _opts}] =
               FakeClient.calls(:fetch_prompt)
    end

    test "falls back to bundle when demand fetch fails and throttles the failure" do
      attach_telemetry([@stale, @fetch_error])
      bundle = tmp_path("bundle.json")
      write_snapshot_file(bundle, Fixtures.snapshot(), %{"etag" => ~s("bundle-e1")})

      FakeClient.set(:fetch_prompt, fn "diary_generation", ~s("bundle-e1"), _opts ->
        {:error, :timeout}
      end)

      start_sdk(bundle: {:file, bundle})

      assert {:ok, %{source: :bundle, etag: ~s("bundle-e1")}} =
               PromptOnSDK.prompt("diary_generation")

      assert_receive {:telemetry, @fetch_error, _,
                      %{reason: :timeout, prompt_key: "diary_generation"}},
                     500

      assert_receive {:telemetry, @stale, %{age_seconds: age}, %{source: :bundle}},
                     500

      assert is_integer(age)

      assert {:ok, %{source: :bundle}} = PromptOnSDK.prompt("diary_generation")
      assert length(FakeClient.calls(:fetch_prompt)) == 1
    end

    test "rejects disk/bundle snapshot whose environment does not match the configured one" do
      path = tmp_path("staging.json")

      write_snapshot_file(path, Map.put(Fixtures.snapshot(), "environment", "staging"), %{
        "etag" => ~s("s1")
      })

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          start_sdk(mode: :offline, disk_cache: path, api_key: nil)
          assert PromptOnSDK.prompt("diary_generation") == {:error, :not_ready}
        end)

      assert log =~
               "environment \"staging\" does not match the configured environment \"production\""
    end

    test "a staging app loads a staging snapshot without network" do
      path = tmp_path("staging.json")

      write_snapshot_file(path, Map.put(Fixtures.snapshot(), "environment", "staging"), %{
        "etag" => ~s("s1")
      })

      start_sdk(mode: :offline, api_key: nil, environment: "staging", disk_cache: path)
      assert {:ok, %{source: :disk}} = PromptOnSDK.prompt("diary_generation")
      assert FakeClient.calls() == []
      assert PromptOnSDK.refresh_prompt_document() == :ok
    end

    test "sidecar prompt documents must match the base disk scope" do
      path = tmp_path("scoped-cache.json")

      staging = shared_model_json("a", "provider/staging-base") |> Jason.decode!()
      staging = Map.put(staging, "environment", "staging")

      production_doc = shared_model_json("a", "provider/production-sidecar") |> Jason.decode!()

      body = Jason.encode!(staging)

      :ok =
        Store.write_file(path, body, %{
          "etag" => ~s("staging-e1"),
          "prompt_documents" => %{"a" => production_doc}
        })

      start_sdk(mode: :offline, api_key: nil, environment: "staging", disk_cache: path)

      assert {:ok, %{model: "provider/staging-base", source: :disk}} = PromptOnSDK.prompt("a")
    end

    test "corrupt disk cache is skipped in favour of the bundle" do
      bad = tmp_path("bad.json")
      File.write!(bad, "{not json")
      bundle = tmp_path("bundle.json")
      write_snapshot_file(bundle, Fixtures.snapshot())

      start_sdk(mode: :offline, disk_cache: bad, bundle: {:file, bundle})
      assert {:ok, %{source: :bundle}} = PromptOnSDK.prompt("diary_generation")
    end
  end

  describe "demand fetch" do
    test "cold prompt lookup fetches only the requested key" do
      attach_telemetry([@updated])

      FakeClient.set(:fetch_prompt, fn "diary_generation", nil, opts ->
        assert opts[:prompt_key] == "diary_generation"
        ok_200(snapshot_json(), ~s("e2"))
      end)

      start_sdk()

      assert {:ok, %{source: :remote, etag: ~s("e2")}} =
               PromptOnSDK.prompt("diary_generation")

      assert_receive {:telemetry, @updated, %{},
                      %{etag: ~s("e2"), source: :remote, environment: "production"}},
                     500

      assert [{:fetch_prompt, "diary_generation", nil, _opts}] = FakeClient.calls(:fetch_prompt)
    end

    test "fresh cache hit does not fetch again, expired cache fetches once" do
      FakeClient.set(:fetch_prompt, fn "diary_generation", _etag, _opts ->
        ok_200(snapshot_json(), ~s("fresh-e1"))
      end)

      start_sdk()

      assert {:ok, %{etag: ~s("fresh-e1")}} = PromptOnSDK.prompt("diary_generation")
      assert {:ok, %{etag: ~s("fresh-e1")}} = PromptOnSDK.prompt("diary_generation")
      assert length(FakeClient.calls(:fetch_prompt)) == 1

      age_key("diary_generation", 10_001)

      FakeClient.set(:fetch_prompt, fn "diary_generation", ~s("fresh-e1"), _opts ->
        ok_200(snapshot_json(), ~s("fresh-e2"))
      end)

      assert {:ok, %{etag: ~s("fresh-e2")}} = PromptOnSDK.prompt("diary_generation")
      assert length(FakeClient.calls(:fetch_prompt)) == 2
    end

    test "304 is success only when a cached prompt exists" do
      path = tmp_path("cache.json")
      write_snapshot_file(path, Fixtures.snapshot(), %{"etag" => ~s("disk-e1")})

      FakeClient.set(:fetch_prompt, fn "diary_generation", ~s("disk-e1"), _opts ->
        {:ok, %{status: 304}}
      end)

      start_sdk(disk_cache: path)

      assert {:ok, %{source: :remote, etag: ~s("disk-e1")}} =
               PromptOnSDK.prompt("diary_generation")
    end

    test "304 without cached value is a failure" do
      attach_telemetry([@fetch_error])

      FakeClient.set(:fetch_prompt, fn "diary_generation", nil, _opts -> {:ok, %{status: 304}} end)

      start_sdk()

      assert PromptOnSDK.prompt("diary_generation") == {:error, :not_ready}
      assert_receive {:telemetry, @fetch_error, _, %{reason: :unexpected_304}}, 500
    end

    test "failed expired fetch returns stale cache and does not retry inside 10 seconds" do
      FakeClient.set(:fetch_prompt, fn "diary_generation", _etag, _opts ->
        ok_200(snapshot_json(), ~s("stale-e1"))
      end)

      start_sdk()
      assert {:ok, %{etag: ~s("stale-e1")}} = PromptOnSDK.prompt("diary_generation")
      age_key("diary_generation", 10_001)

      FakeClient.set(:fetch_prompt, fn "diary_generation", ~s("stale-e1"), _opts ->
        {:error, :econnrefused}
      end)

      assert {:ok, %{etag: ~s("stale-e1")}} = PromptOnSDK.prompt("diary_generation")
      assert {:ok, %{etag: ~s("stale-e1")}} = PromptOnSDK.prompt("diary_generation")
      assert length(FakeClient.calls(:fetch_prompt)) == 2
    end

    test "no cache plus failed fetch returns not_ready" do
      FakeClient.set(:fetch_prompt, fn "diary_generation", nil, _opts -> {:error, :offline} end)
      start_sdk()

      assert PromptOnSDK.prompt("diary_generation") == {:error, :not_ready}
      assert PromptOnSDK.prompt("diary_generation") == {:error, :not_ready}
      assert length(FakeClient.calls(:fetch_prompt)) == 1
    end

    test "slow fetch has a one second total budget and late responses do not write cache" do
      test_pid = self()

      FakeClient.set(:fetch_prompt, fn "diary_generation", nil, _opts ->
        send(test_pid, {:fetch_pid, self()})
        Process.sleep(1_200)
        send(test_pid, :fetch_completed)
        ok_200(snapshot_json(), ~s("late-e1"))
      end)

      start_sdk()
      started = System.monotonic_time(:millisecond)

      assert PromptOnSDK.prompt("diary_generation") == {:error, :not_ready}
      assert System.monotonic_time(:millisecond) - started < 1_150

      Process.sleep(300)
      assert PromptOnSDK.prompt("diary_generation") == {:error, :not_ready}
      assert Store.get() == nil
      assert length(FakeClient.calls(:fetch_prompt)) == 1
      assert_receive {:fetch_pid, fetch_pid}, 100
      refute Process.alive?(fetch_pid)
      refute_receive :fetch_completed, 10
    end

    test "absolute deadline rejects a response delivered before the timeout message" do
      test_pid = self()

      FakeClient.set(:fetch_prompt, fn "diary_generation", nil, _opts ->
        send(test_pid, :fetch_started)
        Process.sleep(50)
        ok_200(snapshot_json(), ~s("after-deadline"))
      end)

      start_sdk()
      task = Task.async(fn -> PromptOnSDK.prompt("diary_generation") end)
      assert_receive :fetch_started, 500

      :sys.replace_state(Snapshot, fn state ->
        flight = Map.fetch!(state.inflight, "diary_generation")
        flight = %{flight | deadline_ms: System.monotonic_time(:millisecond) - 1}
        %{state | inflight: Map.put(state.inflight, "diary_generation", flight)}
      end)

      assert Task.await(task, 500) == {:error, :not_ready}
      assert Store.get() == nil
    end

    test "the one second deadline includes decode and validation before install" do
      test_pid = self()
      body = large_snapshot_json(100_000)

      FakeClient.set(:fetch_prompt, fn "diary_generation", nil, _opts ->
        send(test_pid, {:ready_to_return, self()})

        receive do
          :release_fetch -> ok_200(body, ~s("decode-after-deadline"))
        after
          1_000 -> {:error, :test_timeout}
        end
      end)

      start_sdk()
      task = Task.async(fn -> PromptOnSDK.prompt("diary_generation") end)
      assert_receive {:ready_to_return, fetch_pid}, 500

      :sys.replace_state(Snapshot, fn state ->
        flight = Map.fetch!(state.inflight, "diary_generation")
        flight = %{flight | deadline_ms: System.monotonic_time(:millisecond) + 200}
        %{state | inflight: Map.put(state.inflight, "diary_generation", flight)}
      end)

      send(fetch_pid, :release_fetch)

      assert Task.await(task, 1_500) == {:error, :not_ready}
      assert Store.get() == nil
    end

    test "same-key concurrent callers share one fetch" do
      test_pid = self()

      FakeClient.set(:fetch_prompt, fn "diary_generation", nil, _opts ->
        send(test_pid, :fetch_started)
        Process.sleep(50)
        ok_200(snapshot_json(), ~s("singleflight-e1"))
      end)

      start_sdk()

      tasks =
        for _ <- 1..5 do
          Task.async(fn -> PromptOnSDK.prompt("diary_generation") end)
        end

      assert_receive :fetch_started, 500

      assert Enum.all?(Task.await_many(tasks, 1_000), fn
               {:ok, %{etag: ~s("singleflight-e1")}} -> true
               _ -> false
             end)

      assert length(FakeClient.calls(:fetch_prompt)) == 1
    end

    test "different keys are not serialized behind a slow fetch" do
      FakeClient.set(:fetch_prompt, fn
        "diary_generation", nil, _opts ->
          Process.sleep(1_200)
          ok_200(snapshot_json_for("diary_generation"), ~s("slow-e1"))

        "chat_response", nil, _opts ->
          ok_200(snapshot_json_for("chat_response"), ~s("fast-e1"))
      end)

      start_sdk()

      slow = Task.async(fn -> PromptOnSDK.prompt("diary_generation") end)
      Process.sleep(50)

      started = System.monotonic_time(:millisecond)

      assert {:ok, %{key: "chat_response", etag: ~s("fast-e1")}} =
               PromptOnSDK.prompt("chat_response")

      assert System.monotonic_time(:millisecond) - started < 500
      assert Task.await(slow, 1_500) == {:error, :unknown_prompt}
    end

    test "scope mismatch is rejected and stale cache is retained" do
      FakeClient.set(:fetch_prompt, fn "diary_generation", _etag, _opts ->
        ok_200(snapshot_json(), ~s("scope-e1"))
      end)

      start_sdk()
      assert {:ok, %{etag: ~s("scope-e1")}} = PromptOnSDK.prompt("diary_generation")
      age_key("diary_generation", 10_001)

      FakeClient.set(:fetch_prompt, fn "diary_generation", ~s("scope-e1"), _opts ->
        ok_200(snapshot_json(%{"environment" => "staging"}), ~s("bad-env"))
      end)

      assert {:ok, %{etag: ~s("scope-e1")}} = PromptOnSDK.prompt("diary_generation")
    end

    test "missing remote project is rejected when a local project is known" do
      FakeClient.set(:fetch_prompt, fn "diary_generation", _etag, _opts ->
        ok_200(snapshot_json(), ~s("project-e1"))
      end)

      start_sdk()
      assert {:ok, %{etag: ~s("project-e1")}} = PromptOnSDK.prompt("diary_generation")
      age_key("diary_generation", 10_001)

      FakeClient.set(:fetch_prompt, fn "diary_generation", ~s("project-e1"), _opts ->
        body = Fixtures.snapshot() |> Map.delete("project") |> Jason.encode!()
        ok_200(body, ~s("missing-project"))
      end)

      assert {:ok, %{etag: ~s("project-e1")}} = PromptOnSDK.prompt("diary_generation")
      assert length(FakeClient.calls(:fetch_prompt)) == 2
    end

    test "updating another key with shared ids does not mutate a fresh prompt handle" do
      FakeClient.set(:fetch_prompt, fn
        "a", nil, _opts -> ok_200(shared_model_json("a", "provider/a-old"), ~s("a-e1"))
        "b", nil, _opts -> ok_200(shared_model_json("b", "provider/b-new"), ~s("b-e1"))
      end)

      start_sdk()

      assert {:ok, %{model: "provider/a-old", etag: ~s("a-e1")}} = PromptOnSDK.prompt("a")
      assert {:ok, %{model: "provider/b-new", etag: ~s("b-e1")}} = PromptOnSDK.prompt("b")

      assert {:ok, %{model: "provider/a-old", etag: ~s("a-e1")}} = PromptOnSDK.prompt("a")
      assert length(FakeClient.calls(:fetch_prompt)) == 2

      age_key("a", 10_001)

      FakeClient.set(:fetch_prompt, fn "a", ~s("a-e1"), _opts ->
        ok_200(shared_model_json("a", "provider/a-new"), ~s("a-e2"))
      end)

      assert {:ok, %{model: "provider/a-new", etag: ~s("a-e2")}} = PromptOnSDK.prompt("a")
    end

    test "runtime requires fetch_prompt/4 and does not silently fall back to bulk fetch_prompts/3" do
      attach_telemetry([@fetch_error])
      start_sdk(client: LegacyOnlyClient)

      assert PromptOnSDK.prompt("diary_generation") == {:error, :not_ready}
      assert_receive {:telemetry, @fetch_error, _, %{reason: :missing_fetch_callback}}, 500
    end

    test "manual refresh follows the same gate and singleflight path" do
      FakeClient.set(:fetch_prompt, fn "diary_generation", nil, _opts ->
        ok_200(snapshot_json(), ~s("manual-e1"))
      end)

      start_sdk()
      assert PromptOnSDK.refresh_prompt_document() == :ok
      assert FakeClient.calls() == []

      assert PromptOnSDK.refresh_prompt_document("diary_generation") == :ok
      assert {:ok, %{etag: ~s("manual-e1")}} = PromptOnSDK.prompt("diary_generation")
      assert length(FakeClient.calls(:fetch_prompt)) == 1

      assert PromptOnSDK.refresh_prompt_document() == :ok
      assert PromptOnSDK.refresh_prompt_document("diary_generation") == :ok
      assert length(FakeClient.calls(:fetch_prompt)) == 1

      age_key("diary_generation", 10_001)

      test_pid = self()

      FakeClient.set(:fetch_prompt, fn "diary_generation", ~s("manual-e1"), _opts ->
        send(test_pid, :manual_fetch_started)
        Process.sleep(100)
        ok_200(snapshot_json(), ~s("manual-e2"))
      end)

      task = Task.async(fn -> PromptOnSDK.prompt("diary_generation") end)
      assert_receive :manual_fetch_started, 500
      assert PromptOnSDK.refresh_prompt_document() == :ok
      assert {:ok, %{etag: ~s("manual-e2")}} = Task.await(task, 500)
      assert length(FakeClient.calls(:fetch_prompt)) == 2
    end

    test "successful per-key remote configs persist to disk and survive restart independently" do
      path = tmp_path("cache.json")

      FakeClient.set(:fetch_prompt, fn
        "a", nil, _opts -> ok_200(shared_model_json("a", "provider/a-old"), ~s("a-e1"))
        "b", nil, _opts -> ok_200(shared_model_json("b", "provider/b-new"), ~s("b-e1"))
      end)

      start_sdk(disk_cache: path)

      assert {:ok, %{model: "provider/a-old"}} = PromptOnSDK.prompt("a")
      assert {:ok, %{model: "provider/b-new"}} = PromptOnSDK.prompt("b")
      wait_until(fn -> File.exists?(path) and File.exists?(path <> ".meta.json") end)

      stop_supervised!(PromptOnSDK)
      Store.erase()
      PromptOnSDK.Config.erase()
      FakeClient.reset()

      start_sdk(mode: :offline, api_key: nil, disk_cache: path)

      assert {:ok, %{model: "provider/a-old", source: :disk}} = PromptOnSDK.prompt("a")
      assert {:ok, %{model: "provider/b-new", source: :disk}} = PromptOnSDK.prompt("b")
      assert FakeClient.calls() == []
    end

    test "remote v6 Decision snapshots prepare System One requests" do
      FakeClient.set(:fetch_prompt, fn "route", nil, _opts ->
        ok_200(decision_snapshot_json(), ~s("decision-v6"))
      end)

      start_sdk()

      assert {:ok, prompt} = PromptOnSDK.prompt("route")

      assert {:ok, %{api: :decisions, path: "/api/v1/systemone", body: request_body}} =
               PromptOnSDK.request(prompt, %{input: "hello", team: "Support"})

      assert request_body["state"] == %{"message" => "hello"}
      assert get_in(request_body, ["questions", "route", "instructions"]) == "Route Support"
    end
  end

  describe "modes" do
    test ":test mode never touches the client and refresh is a no-op" do
      start_sdk(mode: :test)
      assert FakeClient.calls() == []
      assert PromptOnSDK.refresh_prompt_document() == :ok
      assert PromptOnSDK.prompt("x", %{}) == {:error, :not_ready}
    end

    test "live without api_key/base_url runs on local snapshot only" do
      bundle = tmp_path("bundle.json")
      write_snapshot_file(bundle, Fixtures.snapshot())
      start_sdk(api_key: nil, base_url: nil, bundle: {:file, bundle})
      assert FakeClient.calls() == []
      assert {:ok, %{source: :bundle}} = PromptOnSDK.prompt("diary_generation")
      assert PromptOnSDK.refresh_prompt_document() == {:error, :remote_disabled}
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
