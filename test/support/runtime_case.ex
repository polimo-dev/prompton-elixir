defmodule PromptOnSDK.RuntimeCase do
  @moduledoc """
  Shared setup for runtime tests (supervisor, persistent_term, fake client). `async: false` only.

  * Starts `PromptOnSDK.FakeClient`, and after each test clears persistent_term (snapshot/config)
    and the app env.
  * `start_sdk/1`: starts `{PromptOnSDK, opts}` via `start_supervised!` (defaults: `:live`, the
    `ptn_production_test` key, FakeClient, short intervals).
  * `tmp_path/1`: a per-test temporary file path.
  * `attach_telemetry/1`: forwards events to the test process
    (`{:telemetry, event, measurements, metadata}`).
  """

  use ExUnit.CaseTemplate

  alias PromptOnSDK.Snapshot.Store

  using do
    quote do
      @moduletag :capture_log
      import PromptOnSDK.RuntimeCase
      alias PromptOnSDK.{FakeClient, Fixtures}
      alias PromptOnSDK.Snapshot.Store
    end
  end

  setup do
    start_supervised!(PromptOnSDK.FakeClient)
    Store.erase()
    PromptOnSDK.Config.erase()
    :persistent_term.erase({PromptOnSDK, :no_buffer_warned_at})

    on_exit(fn ->
      Store.erase()
      PromptOnSDK.Config.erase()
      :persistent_term.erase({PromptOnSDK, :no_buffer_warned_at})

      for {key, _} <- Application.get_all_env(:prompton_sdk) do
        Application.delete_env(:prompton_sdk, key)
      end
    end)

    :ok
  end

  def default_opts do
    [
      mode: :live,
      api_key: "ptn_production_secret",
      base_url: "http://prompton.test/api/v1",
      client: PromptOnSDK.FakeClient,
      poll_interval: 60_000,
      log: [flush_interval: 50, flush_size: 100, flush_bytes: 1_000_000, max_buffer: 10_000]
    ]
  end

  def start_sdk(opts \\ []) do
    opts = Keyword.merge(default_opts(), opts)
    ExUnit.Callbacks.start_supervised!({PromptOnSDK, opts})
  end

  def tmp_dir do
    dir =
      Path.join(
        System.tmp_dir!(),
        "prompton_sdk_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  def tmp_path(name), do: Path.join(tmp_dir(), name)

  def write_snapshot_file(path, snapshot_map, meta \\ %{}) do
    body = Jason.encode!(snapshot_map)
    :ok = Store.write_file(path, body, meta)
    body
  end

  def attach_telemetry(events) do
    pid = self()
    id = "test-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(id, events, &__MODULE__.handle_event/4, pid)

    ExUnit.Callbacks.on_exit(fn -> :telemetry.detach(id) end)
    :ok
  end

  @doc false
  def handle_event(event, measurements, metadata, pid) do
    send(pid, {:telemetry, event, measurements, metadata})
  end

  @doc "Polls briefly until the condition becomes true."
  def eventually(fun, timeout \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_eventually(fun, deadline)
  end

  defp do_eventually(fun, deadline) do
    case fun.() do
      true ->
        true

      _ ->
        if System.monotonic_time(:millisecond) > deadline do
          flunk_eventually()
        else
          Process.sleep(10)
          do_eventually(fun, deadline)
        end
    end
  end

  defp flunk_eventually, do: raise(ExUnit.AssertionError, message: "condition never became true")

  def ok_202(accepted \\ 0) do
    {:ok,
     %{
       status: 202,
       body: %{"accepted" => accepted, "duplicates" => 0, "rejected" => []},
       headers: %{}
     }}
  end
end
