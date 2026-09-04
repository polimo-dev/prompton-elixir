defmodule PromptOnSDK.Snapshot do
  @moduledoc """
  Snapshot loader/poller GenServer (§7.3). The result goes into `PromptOnSDK.Snapshot.Store`
  (`:persistent_term`); `PromptOnSDK.resolve/3` bypasses this process and reads only the
  persistent_term.

  ## Fallback chain

      init: load disk cache → bundle synchronously (if present, valid, and the environment matches)
      handle_continue: GET /snapshot (receive_timeout 3s); does not block boot
        200 → replace persistent_term + atomic disk cache write (+ sidecar)
              + [:prompton, :snapshot, :updated], source :remote
        304 → no-op (if we came up from disk/bundle, promote to :remote; the server confirmed
              "that ETag is current")
        failure → keep the existing entry (record stale_since)
              + [:prompton, :snapshot, :fetch_error] + [:prompton, :snapshot, :stale] (age)
              with no entry, resolve returns {:error, :not_ready}
      afterwards: If-None-Match polling every poll_interval. Failures back off exponentially,
              poll_interval×2ⁿ (default 30s → 60 → 120 → 240 → 300s cap)

  ## Modes

  * `:live`: all of the above.
  * `:offline`: no HTTP. Loads disk/bundle only (CI, local). `refresh/0` re-reads the files.
  * `:test`: does nothing. Snapshots are injected with `PromptOnSDK.Test.put_snapshot/1`.

  Without `api_key` or `base_url`, the remote is not called even in `:live` (one warning).

  ## Environment guard

  If a disk/bundle snapshot's `environment` differs from the configured `environment`
  (`config.env_slug`), it is rejected + `Logger.warning`. The next fallback is tried; if all
  fail, `source: :none`.
  """

  use GenServer
  require Logger

  alias PromptOnSDK.Snapshot.Store
  alias PromptOnSDK.SnapshotData
  alias PromptOnSDK.Telemetry

  @initial_fetch_timeout 3_000
  @backoff_cap 300_000

  defstruct config: nil, timer: nil, failures: 0, remote?: false

  # ---------------------------------------------------------------------------
  # public

  @doc false
  def start_link(config) do
    GenServer.start_link(__MODULE__, config, name: __MODULE__)
  end

  @doc "Synchronous reload: remote fetch in `:live`, file reload in `:offline`, `:ok` in `:test`."
  @spec refresh(timeout()) :: :ok | {:error, term()}
  def refresh(timeout \\ 15_000) do
    GenServer.call(__MODULE__, :refresh, timeout)
  catch
    :exit, {:noproc, _} -> {:error, :not_started}
    :exit, {:timeout, _} -> {:error, :timeout}
  end

  @doc "`PromptOnSDK.snapshot_info/0`."
  @spec info() :: map()
  def info, do: Store.info(Store.get())

  # ---------------------------------------------------------------------------
  # callbacks

  @impl true
  def init(config) do
    state = %__MODULE__{config: config}

    case config.mode do
      :test ->
        {:ok, state}

      :offline ->
        load_local(config)
        {:ok, state}

      :live ->
        load_local(config)

        if remote_enabled?(config) do
          {:ok, %{state | remote?: true}, {:continue, :initial_fetch}}
        else
          Logger.warning(
            "[PromptOn] api_key/base_url not configured — running on #{describe_source()} only"
          )

          {:ok, state}
        end
    end
  end

  @impl true
  def handle_continue(:initial_fetch, state) do
    state = do_fetch(state, receive_timeout: @initial_fetch_timeout)
    {:noreply, schedule(state)}
  end

  @impl true
  def handle_info(:poll, state) do
    state = do_fetch(%{state | timer: nil}, [])
    {:noreply, schedule(state)}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def handle_call(:refresh, _from, %{config: %{mode: :test}} = state), do: {:reply, :ok, state}

  def handle_call(:refresh, _from, %{config: %{mode: :offline} = config} = state) do
    case load_local(config) do
      :ok -> {:reply, :ok, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:refresh, _from, %{remote?: false} = state) do
    {:reply, {:error, :remote_disabled}, state}
  end

  def handle_call(:refresh, _from, state) do
    state = cancel_timer(state)
    {result, state} = fetch(state, [])
    {:reply, result, schedule(state)}
  end

  # ---------------------------------------------------------------------------
  # local loading

  defp load_local(config) do
    candidates =
      [
        config.disk_cache && {config.disk_cache, :disk},
        case config.bundle do
          {:file, path} -> {path, :bundle}
          _ -> nil
        end
      ]
      |> Enum.reject(&is_nil/1)

    Enum.reduce_while(candidates, {:error, :no_local_snapshot}, fn {path, source}, acc ->
      case Store.load_file(path, source, config.env_slug) do
        {:ok, entry} ->
          Store.put(entry)
          Logger.info("[PromptOn] loaded snapshot from #{source} (#{path}), etag=#{entry.etag}")
          {:halt, :ok}

        {:error, {:file, :enoent}} ->
          {:cont, acc}

        {:error, {:environment_mismatch, file_env, key_env}} ->
          Logger.warning(
            "[PromptOn] rejected #{source} snapshot #{path}: environment #{inspect(file_env)} " <>
              "does not match the configured environment #{inspect(key_env)}"
          )

          {:cont, {:error, {:environment_mismatch, file_env, key_env}}}

        {:error, reason} ->
          Logger.warning(
            "[PromptOn] could not load #{source} snapshot #{path}: #{inspect(reason)}"
          )

          {:cont, {:error, reason}}
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # remote fetching

  defp do_fetch(state, opts) do
    {_result, state} = fetch(state, opts)
    state
  end

  defp fetch(%{config: config} = state, opts) do
    current = Store.get()
    etag = current && current.etag

    result =
      try do
        config.client.fetch_snapshot(config, etag, opts)
      rescue
        e -> {:error, {:client_exception, e}}
      catch
        kind, value -> {:error, {:client_exit, kind, value}}
      end

    case result do
      {:ok, %{status: 200} = resp} ->
        handle_200(resp, current, state)

      {:ok, %{status: 304}} ->
        handle_304(current, state)

      {:ok, %{status: status} = resp} ->
        handle_failure({:http, status, Map.get(resp, :body)}, current, state)

      {:error, reason} ->
        handle_failure(reason, current, state)
    end
  end

  defp handle_200(resp, current, state) do
    case decode_body(resp.body) do
      {:ok, data, warnings} ->
        warn_decode(warnings)
        install_remote(resp, data, current, state)

      {:error, reason} ->
        handle_failure({:decode, reason}, current, state)
    end
  end

  defp install_remote(resp, data, current, %{config: config} = state) do
    entry =
      Store.new_entry(data, :remote,
        etag: resp.etag,
        last_modified: resp.last_modified,
        fetched_at: DateTime.utc_now()
      )

    Store.put(entry)
    persist_disk(config, resp.body, entry)

    Telemetry.execute(Telemetry.snapshot_updated(), %{}, %{
      etag: entry.etag,
      source: :remote,
      environment: data.environment,
      previous_etag: current && current.etag
    })

    Logger.info("[PromptOn] snapshot updated etag=#{entry.etag} env=#{data.environment}")
    {:ok, %{state | failures: 0}}
  end

  defp handle_304(nil, state) do
    # A 304 with no entry? We sent no ETag, so this does not happen in a healthy state. Treat it
    # as a failure.
    handle_failure(:unexpected_304, nil, state)
  end

  defp handle_304(current, state) do
    if current.source != :remote or current.stale_since != nil do
      Store.put(%{current | source: :remote, stale_since: nil})
    end

    {:ok, %{state | failures: 0}}
  end

  defp handle_failure(reason, current, state) do
    failures = state.failures + 1
    state = %{state | failures: failures}
    now = DateTime.utc_now()

    Telemetry.execute(Telemetry.snapshot_fetch_error(), %{}, %{
      reason: reason,
      attempt: failures,
      next_retry_ms: next_interval(state)
    })

    Logger.warning("[PromptOn] snapshot fetch failed (attempt #{failures}): #{inspect(reason)}")

    case current do
      nil ->
        :ok

      entry ->
        entry = if entry.stale_since, do: entry, else: %{entry | stale_since: now}
        Store.put(entry)

        Telemetry.execute(
          Telemetry.snapshot_stale(),
          %{age_seconds: Store.age_seconds(entry, now) || 0},
          %{source: entry.source, reason: reason, etag: entry.etag}
        )
    end

    {{:error, reason}, state}
  end

  defp decode_body(body) when is_binary(body), do: SnapshotData.decode_json(body)
  defp decode_body(body) when is_map(body), do: SnapshotData.decode(body)
  defp decode_body(other), do: {:error, {:invalid_snapshot, "unexpected body #{inspect(other)}"}}

  defp warn_decode([]), do: :ok

  defp warn_decode(warnings) do
    Logger.warning("[PromptOn] snapshot decoded with warnings: #{inspect(warnings)}")
  end

  defp persist_disk(%{disk_cache: nil}, _body, _entry), do: :ok

  defp persist_disk(%{disk_cache: path}, body, entry) do
    bytes =
      case body do
        b when is_binary(b) -> b
        m when is_map(m) -> Jason.encode!(m)
      end

    meta = %{
      "etag" => entry.etag,
      "last_modified" => entry.last_modified,
      "environment" => entry.environment,
      "fetched_at" => DateTime.to_iso8601(entry.fetched_at)
    }

    case Store.write_file(path, bytes, meta) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("[PromptOn] disk cache write failed #{path}: #{inspect(reason)}")
    end
  end

  # ---------------------------------------------------------------------------
  # scheduling

  defp schedule(%{remote?: false} = state), do: state

  defp schedule(state) do
    state = cancel_timer(state)
    %{state | timer: Process.send_after(self(), :poll, next_interval(state))}
  end

  defp next_interval(%{failures: 0, config: config}), do: config.poll_interval

  defp next_interval(%{failures: n, config: config}) do
    base = config.poll_interval
    cap = max(@backoff_cap, base)
    min(base * Integer.pow(2, min(n - 1, 20)), cap)
  end

  defp cancel_timer(%{timer: nil} = state), do: state

  defp cancel_timer(%{timer: ref} = state) do
    Process.cancel_timer(ref)
    %{state | timer: nil}
  end

  defp remote_enabled?(config), do: is_binary(config.api_key) and is_binary(config.base_url)

  defp describe_source do
    case Store.get() do
      nil -> "nothing (resolve returns {:error, :not_ready})"
      %{source: source} -> "#{source} snapshot"
    end
  end
end
