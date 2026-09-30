defmodule PromptOnSDK.Snapshot do
  @moduledoc false

  use GenServer
  require Logger

  alias PromptOnSDK.PromptDocument
  alias PromptOnSDK.Snapshot.Store
  alias PromptOnSDK.Telemetry

  @fetch_budget_ms 1_000
  @fresh_ms 10_000
  @attempt_gate_ms 10_000

  defstruct config: nil, remote?: false, cache: %{}, inflight: %{}, disk_writer: nil

  # ---------------------------------------------------------------------------
  # public

  @doc false
  def start_link(config) do
    GenServer.start_link(__MODULE__, config, name: __MODULE__)
  end

  @doc false
  @spec ensure_prompt(String.t() | atom(), timeout()) :: :ok | {:error, term()}
  def ensure_prompt(prompt_key, timeout \\ @fetch_budget_ms + 250) do
    GenServer.call(__MODULE__, {:ensure_prompt, to_key(prompt_key)}, timeout)
  catch
    :exit, {:noproc, _} -> :ok
    :exit, {:timeout, _} -> :ok
  end

  @doc """
  Manual refresh for currently known prompt keys. It follows the same per-key demand fetch gate.
  """
  @spec refresh_prompt_document() :: :ok | {:error, term()}
  def refresh_prompt_document do
    refresh_prompt_document(15_000)
  end

  @spec refresh_prompt_document(timeout() | String.t() | atom()) :: :ok | {:error, term()}
  def refresh_prompt_document(timeout) when is_integer(timeout) do
    GenServer.call(__MODULE__, :refresh, timeout)
  catch
    :exit, {:noproc, _} -> {:error, :not_started}
    :exit, {:timeout, _} -> {:error, :timeout}
  end

  def refresh_prompt_document(prompt_key) do
    ensure_prompt(prompt_key)
  end

  @doc "`PromptOnSDK.prompt_document_info/0`."
  @spec info() :: map()
  def info, do: Store.info(Store.get())

  # ---------------------------------------------------------------------------
  # callbacks

  @impl true
  def init(config) do
    state = %__MODULE__{
      config: config,
      remote?: remote_enabled?(config),
      disk_writer: start_disk_writer(config)
    }

    case config.mode do
      :test ->
        {:ok, %{state | remote?: false}}

      :offline ->
        load_local(config)
        {:ok, %{state | remote?: false}}

      :live ->
        load_local(config)

        unless state.remote? do
          Logger.warning(
            "[PromptOn] api_key/base_url not configured - running on #{describe_source()} only"
          )
        end

        {:ok, state}
    end
  end

  @impl true
  def handle_call({:ensure_prompt, key}, from, state) do
    ensure_prompt_call(key, from, state)
  end

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
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:fetch_timeout, key, ref}, state) do
    case Map.pop(state.inflight, key) do
      {%{ref: ^ref} = flight, inflight} ->
        Process.demonitor(flight.monitor, [:flush])
        Process.exit(flight.pid, :kill)
        reply_all(flight.callers, fallback_result(key))
        state = mark_failure(key, :timeout, %{state | inflight: inflight})
        {:noreply, state}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:fetch_result, key, ref, result}, state) do
    case Map.pop(state.inflight, key) do
      {%{ref: ^ref} = flight, inflight} ->
        Process.cancel_timer(flight.timer)
        Process.demonitor(flight.monitor, [:flush])

        {reply, state} =
          if now_ms() > flight.deadline_ms do
            Process.exit(flight.pid, :kill)
            {fallback_result(key), mark_failure(key, :timeout, %{state | inflight: inflight})}
          else
            apply_fetch_result(key, flight, result, %{state | inflight: inflight})
          end

        reply_all(flight.callers, reply)
        {:noreply, state}

      _late_or_superseded ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, _monitor, :process, _pid, _reason}, state), do: {:noreply, state}
  def handle_info(_other, state), do: {:noreply, state}

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

    Enum.reduce_while(candidates, {:error, :no_local_prompt_document}, fn {path, source}, acc ->
      case Store.load_file(path, source, config.env_slug) do
        {:ok, entry} ->
          Store.put(entry)

          Logger.info(
            "[PromptOn] loaded prompt document from #{source} (#{path}), etag=#{entry.etag}"
          )

          {:halt, :ok}

        {:error, {:file, :enoent}} ->
          {:cont, acc}

        {:error, {:environment_mismatch, file_env, key_env}} ->
          Logger.warning(
            "[PromptOn] rejected #{source} prompt document #{path}: environment #{inspect(file_env)} " <>
              "does not match the configured environment #{inspect(key_env)}"
          )

          {:cont, {:error, {:environment_mismatch, file_env, key_env}}}

        {:error, reason} ->
          Logger.warning(
            "[PromptOn] could not load #{source} prompt document #{path}: #{inspect(reason)}"
          )

          {:cont, {:error, reason}}
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # demand fetching

  defp ensure_prompt_call(nil, _from, state), do: {:reply, :ok, state}

  defp ensure_prompt_call(_key, _from, %{config: %{mode: mode}} = state)
       when mode in [:test, :offline] do
    {:reply, :ok, state}
  end

  defp ensure_prompt_call(_key, _from, %{remote?: false} = state), do: {:reply, :ok, state}

  defp ensure_prompt_call(key, from, state) do
    state = maybe_start_fetch(key, from, state)
    if Map.has_key?(state.inflight, key), do: {:noreply, state}, else: {:reply, :ok, state}
  end

  defp maybe_start_fetch(key, from, state) do
    now = now_ms()
    cache = key_cache(key, state)

    cond do
      fresh?(cache, now) ->
        state

      flight = Map.get(state.inflight, key) ->
        callers = if from, do: [from | flight.callers], else: flight.callers
        flight = %{flight | callers: callers}
        %{state | inflight: Map.put(state.inflight, key, flight)}

      attempt_gated?(cache, now) ->
        state

      true ->
        case start_fetch(key, from, state) do
          {:started, state} -> state
          {:skip, state} -> state
        end
    end
  end

  defp start_fetch(key, caller, state) do
    now = now_ms()
    cache = key_cache(key, state) |> Map.put(:last_attempt_ms, now)
    state = put_key_cache(state, key, cache)
    ref = make_ref()
    parent = self()
    config = state.config
    etag = cache[:etag]

    {:ok, pid} =
      Task.Supervisor.start_child(PromptOnSDK.TaskSupervisor, fn ->
        result = fetch_key(config, key, etag)
        send(parent, {:fetch_result, key, ref, result})
      end)

    flight = %{
      ref: ref,
      pid: pid,
      monitor: Process.monitor(pid),
      timer: Process.send_after(self(), {:fetch_timeout, key, ref}, @fetch_budget_ms),
      started_ms: now,
      deadline_ms: now + @fetch_budget_ms,
      callers: if(caller, do: [caller], else: [])
    }

    {:started, %{state | inflight: Map.put(state.inflight, key, flight)}}
  rescue
    reason ->
      state = mark_failure(key, {:task_start_failed, reason}, state)
      {:skip, state}
  end

  defp fetch_key(config, key, etag) do
    opts = [receive_timeout: @fetch_budget_ms, retry: false, prompt_key: key]

    try do
      if client_exported?(config.client, :fetch_prompt, 4) do
        config.client.fetch_prompt(config, key, etag, opts)
      else
        {:error, :missing_fetch_callback}
      end
    rescue
      e -> {:error, {:client_exception, e}}
    catch
      kind, value -> {:error, {:client_exit, kind, value}}
    end
  end

  defp apply_fetch_result(key, flight, {:ok, %{status: 200} = resp}, state) do
    with {:ok, data, warnings} <- decode_body(resp.body),
         :ok <- validate_remote(key, data, Store.get(), state.config),
         :ok <- validate_deadline(flight) do
      warn_decode(warnings)
      install_remote(key, resp, data, state)
    else
      {:error, reason} -> fail_fetch(key, reason, state)
    end
  end

  defp apply_fetch_result(key, _flight, {:ok, %{status: 304}}, state) do
    if cached_prompt?(key) do
      cache =
        key_cache(key, state)
        |> Map.merge(%{last_success_ms: now_ms(), source: :remote, stale_since: nil})

      entry =
        Store.get()
        |> Store.put_prompt_meta(key, prompt_meta_from_cache(cache))

      Store.put(entry)
      {:ok, put_key_cache(state, key, cache)}
    else
      fail_fetch(key, :unexpected_304, state)
    end
  end

  defp apply_fetch_result(key, _flight, {:ok, %{status: status} = resp}, state) do
    fail_fetch(key, {:http, status, Map.get(resp, :body)}, state)
  end

  defp apply_fetch_result(key, _flight, {:error, reason}, state),
    do: fail_fetch(key, reason, state)

  defp install_remote(key, resp, data, state) do
    now = DateTime.utc_now()
    now_ms = now_ms()
    current = Store.get()
    merged = merge_data(current && current.data, data, key)

    cache =
      key_cache(key, state)
      |> Map.merge(%{
        etag: Map.get(resp, :etag),
        last_modified: Map.get(resp, :last_modified),
        source: :remote,
        fetched_at: now,
        stale_since: nil,
        last_success_ms: now_ms
      })

    entry =
      Store.new_entry(merged, :remote,
        etag: current && current.etag,
        last_modified: current && current.last_modified,
        fetched_at: (current && current.fetched_at) || now
      )
      |> merge_prompt_meta(current)
      |> merge_prompt_docs(current)
      |> Store.put_prompt_document(key, data)
      |> Store.put_prompt_meta(key, prompt_meta_from_cache(cache))

    Store.put(entry)
    persist_disk(state, entry)

    Telemetry.execute(Telemetry.prompt_document_updated(), %{}, %{
      etag: cache.etag,
      source: :remote,
      environment: data.environment,
      previous_etag: current && get_in(current, [:prompt_meta, key, :etag]),
      prompt_key: key
    })

    Logger.info(
      "[PromptOn] prompt #{key} config updated etag=#{cache.etag} env=#{data.environment}"
    )

    {:ok, put_key_cache(state, key, cache)}
  end

  defp fail_fetch(key, reason, state) do
    state = mark_failure(key, reason, state)
    {fallback_result(key), state}
  end

  defp mark_failure(key, reason, state) do
    Telemetry.execute(Telemetry.prompt_document_fetch_error(), %{}, %{
      reason: reason,
      attempt: 1,
      next_retry_ms: @attempt_gate_ms,
      prompt_key: key
    })

    Logger.warning("[PromptOn] prompt #{key} config fetch failed: #{inspect(reason)}")

    Store.get()
    |> mark_stale_prompt(key, reason)

    state
  end

  defp mark_stale_prompt(nil, _key, _reason), do: :ok

  defp mark_stale_prompt(entry, key, reason) do
    if Map.has_key?(entry.data.prompts, key) do
      now = DateTime.utc_now()
      meta = Store.prompt_meta(entry, key)
      meta = if meta[:stale_since], do: meta, else: Map.put(meta, :stale_since, now)
      Store.put(Store.put_prompt_meta(entry, key, meta))

      Telemetry.execute(
        Telemetry.prompt_document_stale(),
        %{age_seconds: Store.age_seconds(entry, now) || 0},
        %{source: meta.source, reason: reason, etag: meta.etag, prompt_key: key}
      )
    end
  end

  defp fallback_result(_key), do: :ok

  defp fresh?(%{last_success_ms: last_success}, now) when is_integer(last_success),
    do: now - last_success < @fresh_ms

  defp fresh?(_cache, _now), do: false

  defp attempt_gated?(%{last_attempt_ms: last_attempt}, now) when is_integer(last_attempt),
    do: now - last_attempt < @attempt_gate_ms

  defp attempt_gated?(_cache, _now), do: false

  defp key_cache(key, state) do
    case Map.fetch(state.cache, key) do
      {:ok, cache} ->
        cache

      :error ->
        case Store.get() do
          nil ->
            %{}

          entry ->
            Store.prompt_meta(entry, key)
            |> Map.take([:etag, :last_modified, :source, :fetched_at, :stale_since])
        end
    end
  end

  defp put_key_cache(state, key, cache), do: %{state | cache: Map.put(state.cache, key, cache)}

  defp cached_prompt?(key) do
    case Store.get() do
      nil -> false
      entry -> Map.has_key?(entry.data.prompts, key)
    end
  end

  defp validate_remote(key, data, current, config) do
    cond do
      data.environment != config.environment ->
        {:error, {:environment_mismatch, data.environment, config.environment}}

      current && current.data.project && data.project != current.data.project ->
        {:error, {:project_mismatch, data.project, current.data.project}}

      not Map.has_key?(data.prompts, key) ->
        {:error, {:prompt_mismatch, key}}

      not Map.has_key?(data.deployments, key) ->
        {:error, {:unresolved, key}}

      true ->
        :ok
    end
  end

  defp merge_data(nil, data, _key), do: data

  defp merge_data(%PromptDocument{} = current, data, key) do
    %PromptDocument{
      current
      | schema_version: data.schema_version,
        project: data.project || current.project,
        environment: data.environment || current.environment,
        prompts: Map.put(current.prompts, key, Map.fetch!(data.prompts, key)),
        deployments: Map.put(current.deployments, key, Map.fetch!(data.deployments, key)),
        prompt_versions: Map.merge(current.prompt_versions, data.prompt_versions),
        models: Map.merge(current.models, data.models)
    }
  end

  defp merge_prompt_meta(entry, nil), do: entry
  defp merge_prompt_meta(entry, current), do: %{entry | prompt_meta: current[:prompt_meta] || %{}}

  defp merge_prompt_docs(entry, nil), do: entry
  defp merge_prompt_docs(entry, current), do: %{entry | prompt_docs: current[:prompt_docs] || %{}}

  defp validate_deadline(%{deadline_ms: deadline_ms}) do
    if now_ms() > deadline_ms, do: {:error, :timeout}, else: :ok
  end

  defp start_disk_writer(%{disk_cache: path}) when is_binary(path) do
    case Task.Supervisor.start_child(PromptOnSDK.TaskSupervisor, fn -> disk_writer_loop() end) do
      {:ok, pid} ->
        pid

      {:error, reason} ->
        Logger.warning("[PromptOn] disk cache writer start failed #{path}: #{inspect(reason)}")
        nil
    end
  end

  defp start_disk_writer(_config), do: nil

  defp disk_writer_loop do
    receive do
      {:persist, path, entry} ->
        persist_disk_now(path, entry)
        disk_writer_loop()
    end
  end

  defp persist_disk(%{config: %{disk_cache: path}, disk_writer: writer}, entry)
       when is_binary(path) and is_pid(writer) do
    send(writer, {:persist, path, entry})
    :ok
  end

  defp persist_disk(_state, _entry), do: :ok

  defp persist_disk_now(path, entry) do
    body = Jason.encode!(Store.document_to_map(entry.data))

    meta = %{
      "etag" => entry.etag,
      "last_modified" => entry.last_modified,
      "environment" => entry.environment,
      "fetched_at" => DateTime.to_iso8601(entry.fetched_at),
      "prompts" => encode_prompt_meta(entry.prompt_meta),
      "prompt_documents" => encode_prompt_docs(entry.prompt_docs)
    }

    case Store.write_file(path, body, meta) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("[PromptOn] disk cache write failed #{path}: #{inspect(reason)}")
    end
  end

  defp encode_prompt_meta(prompt_meta) do
    Map.new(prompt_meta || %{}, fn {key, meta} ->
      {key,
       %{
         "etag" => meta[:etag],
         "last_modified" => meta[:last_modified],
         "source" => meta[:source],
         "fetched_at" => meta[:fetched_at] && DateTime.to_iso8601(meta[:fetched_at]),
         "stale_since" => meta[:stale_since] && DateTime.to_iso8601(meta[:stale_since])
       }}
    end)
  end

  defp encode_prompt_docs(prompt_docs) do
    Map.new(prompt_docs || %{}, fn {key, data} -> {key, Store.document_to_map(data)} end)
  end

  defp prompt_meta_from_cache(cache) do
    Map.take(cache, [:etag, :last_modified, :source, :fetched_at, :stale_since])
  end

  defp reply_all(callers, reply) do
    Enum.each(callers, &GenServer.reply(&1, reply))
  end

  defp decode_body(body) when is_binary(body), do: PromptDocument.decode_json(body)
  defp decode_body(body) when is_map(body), do: PromptDocument.decode(body)

  defp decode_body(other),
    do: {:error, {:invalid_prompt_document, "unexpected body #{inspect(other)}"}}

  defp warn_decode([]), do: :ok

  defp warn_decode(warnings) do
    Logger.warning("[PromptOn] prompt document decoded with warnings: #{inspect(warnings)}")
  end

  defp remote_enabled?(config), do: is_binary(config.api_key) and is_binary(config.base_url)

  defp client_exported?(module, function, arity) do
    Code.ensure_loaded?(module) and function_exported?(module, function, arity)
  end

  defp describe_source do
    case Store.get() do
      nil -> "nothing (prompt returns {:error, :not_ready})"
      %{source: source} -> "#{source} prompt document"
    end
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp to_key(key) when is_binary(key), do: key
  defp to_key(key) when is_atom(key) and not is_nil(key), do: Atom.to_string(key)
  defp to_key(_), do: nil
end
