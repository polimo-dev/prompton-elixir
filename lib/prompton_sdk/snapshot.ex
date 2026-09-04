defmodule PromptOnSDK.Snapshot do
  @moduledoc false

  use GenServer
  require Logger

  alias PromptOnSDK.Snapshot.Store
  alias PromptOnSDK.Telemetry
  alias PromptOnSDK.UseCaseDocument

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
  @spec refresh_use_case_document(timeout()) :: :ok | {:error, term()}
  def refresh_use_case_document(timeout \\ 15_000) do
    GenServer.call(__MODULE__, :refresh, timeout)
  catch
    :exit, {:noproc, _} -> {:error, :not_started}
    :exit, {:timeout, _} -> {:error, :timeout}
  end

  @doc "`PromptOnSDK.use_case_document_info/0`."
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

    Enum.reduce_while(candidates, {:error, :no_local_use_case_document}, fn {path, source}, acc ->
      case Store.load_file(path, source, config.env_slug) do
        {:ok, entry} ->
          Store.put(entry)

          Logger.info(
            "[PromptOn] loaded use-case document from #{source} (#{path}), etag=#{entry.etag}"
          )

          {:halt, :ok}

        {:error, {:file, :enoent}} ->
          {:cont, acc}

        {:error, {:environment_mismatch, file_env, key_env}} ->
          Logger.warning(
            "[PromptOn] rejected #{source} use-case document #{path}: environment #{inspect(file_env)} " <>
              "does not match the configured environment #{inspect(key_env)}"
          )

          {:cont, {:error, {:environment_mismatch, file_env, key_env}}}

        {:error, reason} ->
          Logger.warning(
            "[PromptOn] could not load #{source} use-case document #{path}: #{inspect(reason)}"
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
        config.client.fetch_use_cases(config, etag, opts)
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

    Telemetry.execute(Telemetry.use_case_document_updated(), %{}, %{
      etag: entry.etag,
      source: :remote,
      environment: data.environment,
      previous_etag: current && current.etag
    })

    Logger.info("[PromptOn] use-case document updated etag=#{entry.etag} env=#{data.environment}")
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

    Telemetry.execute(Telemetry.use_case_document_fetch_error(), %{}, %{
      reason: reason,
      attempt: failures,
      next_retry_ms: next_interval(state)
    })

    Logger.warning(
      "[PromptOn] use-case document fetch failed (attempt #{failures}): #{inspect(reason)}"
    )

    case current do
      nil ->
        :ok

      entry ->
        entry = if entry.stale_since, do: entry, else: %{entry | stale_since: now}
        Store.put(entry)

        Telemetry.execute(
          Telemetry.use_case_document_stale(),
          %{age_seconds: Store.age_seconds(entry, now) || 0},
          %{source: entry.source, reason: reason, etag: entry.etag}
        )
    end

    {{:error, reason}, state}
  end

  defp decode_body(body) when is_binary(body), do: UseCaseDocument.decode_json(body)
  defp decode_body(body) when is_map(body), do: UseCaseDocument.decode(body)

  defp decode_body(other),
    do: {:error, {:invalid_use_case_document, "unexpected body #{inspect(other)}"}}

  defp warn_decode([]), do: :ok

  defp warn_decode(warnings) do
    Logger.warning("[PromptOn] use-case document decoded with warnings: #{inspect(warnings)}")
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
      nil -> "nothing (use_case returns {:error, :not_ready})"
      %{source: source} -> "#{source} use-case document"
    end
  end
end
