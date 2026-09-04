defmodule PromptOnSDK do
  @moduledoc """
  Top-level module of the PromptOn Elixir SDK: the public API (§7.4).

  The package is split into two layers.

  * **Pure core** (no processes, no HTTP; the server `prompton` app reuses it as a path
    dependency): `PromptOnSDK.SnapshotData`, `PromptOnSDK.Resolver`, `PromptOnSDK.Resolution`,
    `PromptOnSDK.Template`, `PromptOnSDK.StopKind`, `PromptOnSDK.Params`.
  * **Runtime**: `PromptOnSDK.Supervisor` (-> the `PromptOnSDK.Snapshot` poller,
    `PromptOnSDK.TaskSupervisor`, the `PromptOnSDK.Buffer` batcher), `PromptOnSDK.Config`,
    `PromptOnSDK.Client` (+ `Client.Req`), `PromptOnSDK.Payload` (payload policy),
    `PromptOnSDK.Generation` (`with_generation/3`), the `PromptOnSDK.OpenRouter` /
    `PromptOnSDK.Generic` adapters, `PromptOnSDK.UUIDv7`, `PromptOnSDK.Telemetry`, the test mode
    `PromptOnSDK.Test`, and `mix prompton.export`.

  ## Getting started

      # config/runtime.exs
      config :prompton_sdk,
        api_key: System.fetch_env!("PTN_API_KEY"),
        base_url: "https://prompton.example/api/v1",
        disk_cache: "/var/lib/myapp/prompton_snapshot.json",
        bundle: {:file, Application.app_dir(:myapp, "priv/prompton/snapshot.json")}

      # application.ex
      children = [MyApp.Repo, {PromptOnSDK, []}, Oban, MyAppWeb.Endpoint]

  ## Call flow (HeyDiary style)

      {:ok, r} = PromptOnSDK.resolve("diary_generation", prompt: "ko")
      {:ok, msgs} = PromptOnSDK.render(r, %{transcriptions: [...], mode: "fresh"})

      PromptOnSDK.with_generation(r, %{end_user_ref: user.id, trace_id: "oban:1", input_messages: msgs,
                                       variables: %{transcriptions: [...], mode: "fresh"},
                                       context: %{language: "ko", plan: "pro"}}, fn ->
        body = PromptOnSDK.OpenRouter.request_body(r, msgs)
        case Req.post(url, json: body) do
          {:ok, %{status: 200, body: resp}} -> {:ok, PromptOnSDK.OpenRouter.outcome(resp)}
          {:ok, %{status: s, body: b}}      -> {:error, %{kind: :http_5xx, status: s, message: inspect(b)}}
          {:error, e}                       -> {:error, %{kind: :transport, message: inspect(e)}}
        end
      end)

  ## Errors (§7.7)

  * `resolve/2`: `{:error, :not_ready}` (no snapshot: remote, disk, and bundle all failed),
    `{:error, :unknown_use_case}`, `{:error, :unresolved}` (no deployment),
    `{:error, :unknown_prompt}` (the deployment has no prompt with that name)
  * `render/2`: `{:error, reason}` where `reason` is `:no_template`, `{:missing_variable, name}`,
    `{:render, reason}`, or `{:parse, reason}`
  * `log/1`, `feedback/1`: **never raise** (`:ok`).

  ## `render/2` and `variables`

  `render/2` is a pure function and leaves no state on the Resolution. To record the pre-render
  variable values in the log, pass the same map as `meta.variables` of `with_generation/3` (see the
  example above). Request context (free-form tags such as language or plan) is passed the same way,
  as `meta.context`; resolution no longer looks at the context (ADR 0007, revised 2026-09-01).
  """

  require Logger

  alias PromptOnSDK.{
    Buffer,
    Config,
    Generation,
    Payload,
    Resolution,
    Resolver,
    Snapshot,
    Template,
    UUIDv7
  }

  alias PromptOnSDK.Snapshot.Store

  @version Mix.Project.config()[:version]
  @no_buffer_warn_key {PromptOnSDK, :no_buffer_warned_at}
  @warn_interval 60_000

  defmodule RenderError do
    @moduledoc "`PromptOnSDK.render!/2` failure."
    defexception [:reason]

    @impl true
    def message(%{reason: reason}), do: "PromptOn render failed: #{inspect(reason)}"
  end

  @doc "SDK version."
  @spec version() :: String.t()
  def version, do: @version

  @doc """
  Child spec: `{PromptOnSDK, opts}`. `opts` are `PromptOnSDK.Config` keys (they override the app
  env).
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts \\ []) do
    %{
      id: __MODULE__,
      start: {PromptOnSDK.Supervisor, :start_link, [opts]},
      type: :supervisor
    }
  end

  # ---------------------------------------------------------------------------
  # resolve / render / options

  @doc """
  UseCase key -> `%PromptOnSDK.Resolution{}`. `opts`: `prompt:` (the prompt name to pick, default
  `"default"`). The snapshot is read from `:persistent_term`, so no process call is involved.
  """
  @spec resolve(String.t() | atom(), keyword()) ::
          {:ok, Resolution.t()}
          | {:error, :not_ready | :unknown_use_case | :unresolved | :unknown_prompt}
  def resolve(use_case_key, opts \\ []) do
    t0 = System.monotonic_time()

    result =
      case Store.get() do
        nil ->
          {:error, :not_ready}

        entry ->
          Resolver.resolve(entry.data, use_case_key,
            prompt: opts[:prompt],
            source: entry.source,
            etag: entry.etag
          )
      end

    emit_resolve(use_case_key, result, t0)
    result
  end

  defp emit_resolve(use_case_key, result, t0) do
    meta =
      case result do
        {:ok, r} ->
          %{
            source: r.source,
            prompt: r.prompt,
            deployment_id: r.deployment_id,
            deployment_revision: r.deployment_revision,
            result: :ok
          }

        {:error, reason} ->
          %{
            source: nil,
            prompt: nil,
            deployment_id: nil,
            deployment_revision: nil,
            result: reason
          }
      end

    PromptOnSDK.Telemetry.execute(
      PromptOnSDK.Telemetry.resolve_stop(),
      %{duration: System.monotonic_time() - t0},
      Map.put(meta, :use_case, to_string(use_case_key))
    )
  end

  @doc """
  Renders the template. `kind :chat` -> `{:ok, [message]}`, `:text` -> `{:ok, binary}`,
  `:embedding` (no template) -> `{:error, :no_template}`.
  A missing required variable is `{:error, {:missing_variable, name}}` (no empty-string
  substitution).
  """
  @spec render(Resolution.t(), map() | nil) ::
          {:ok, [map()] | String.t()} | {:error, :no_template | Template.render_error()}
  def render(%Resolution{kind: :chat, messages: messages} = r, vars) when is_list(messages) do
    Template.render_messages(messages, vars, engine: r.engine || :liquid)
  end

  def render(%Resolution{kind: :text, text_template: text} = r, vars) when is_binary(text) do
    Template.render(text, vars, engine: r.engine || :liquid)
  end

  def render(%Resolution{}, _vars), do: {:error, :no_template}

  @doc "Raising version of `render/2` (`PromptOnSDK.RenderError`)."
  @spec render!(Resolution.t(), map() | nil) :: [map()] | String.t()
  def render!(%Resolution{} = r, vars) do
    case render(r, vars) do
      {:ok, rendered} -> rendered
      {:error, reason} -> raise RenderError, reason: reason
    end
  end

  @doc """
  The **list of prompt names** (sorted) pinned by this UseCase's live deployment. `{:ok, []}` when
  there is no deployment. This list is exactly the set of values accepted by `resolve/2`'s
  `prompt:`.
  """
  @spec prompt_names(String.t() | atom()) ::
          {:ok, [String.t()]} | {:error, :not_ready | :unknown_use_case}
  def prompt_names(use_case_key) do
    case Store.get() do
      nil -> {:error, :not_ready}
      entry -> Resolver.prompt_names(entry.data, use_case_key)
    end
  end

  # ---------------------------------------------------------------------------
  # logging

  @doc "Pre-issues a UUIDv7 (for later scoring and for storing the app's own row)."
  @spec generation_id() :: String.t()
  def generation_id, do: UUIDv7.generate()

  @doc """
  Enqueues one generation asynchronously (§6.4 format, atom or string keys). **Never raises.**

  * Fills in `id`/`started_at`/`sdk` when they are absent.
  * Applies the payload policy (`PromptOnSDK.Payload`): `opts[:policy]` (the Resolution's
    `payload_policy`) or the current snapshot's policy for that UseCase, else
    `config.payload_defaults`.
  * With `mode: :test`, sends `{:prompton_generation, gen}` to the **calling process** instead of
    the Buffer (`PromptOnSDK.Test.assert_logged/1`).
  * If the Buffer is not running, drops the item and warns (once per minute).
  """
  @spec log(map(), keyword()) :: :ok
  def log(gen, opts \\ []) do
    config = Config.get()
    gen = gen |> deep_stringify() |> put_defaults()
    policy = Keyword.get(opts, :policy) || snapshot_policy(gen["use_case"])
    gen = Payload.apply(gen, policy, config)
    dispatch(:generations, {:prompton_generation, gen}, gen, config)
  rescue
    e ->
      Logger.warning("[PromptOn] log/1 dropped a generation: #{Exception.message(e)}")
      :ok
  catch
    kind, value ->
      Logger.warning("[PromptOn] log/1 dropped a generation: #{inspect({kind, value})}")
      :ok
  end

  @doc """
  One feedback item (§6.5: `generation_id`★, `kind`★, `value`, `comment`, `end_user_ref`,
  `occurred_at`, `evaluator` (kind "score")).
  Enqueued asynchronously, never raises. With `mode: :test`, sends `{:prompton_feedback, map}` to
  the calling process.
  """
  @spec feedback(map()) :: :ok
  def feedback(map) do
    config = Config.get()

    item =
      map
      |> deep_stringify()
      |> Map.put_new_lazy("occurred_at", fn -> DateTime.to_iso8601(DateTime.utc_now()) end)

    if is_nil(item["generation_id"]) or is_nil(item["kind"]) do
      Logger.warning("[PromptOn] feedback/1 dropped: generation_id and kind are required")
      :ok
    else
      item = hash_feedback_user(item, config)
      dispatch(:feedback, {:prompton_feedback, item}, item, config)
    end
  rescue
    e ->
      Logger.warning("[PromptOn] feedback/1 dropped: #{Exception.message(e)}")
      :ok
  end

  defp hash_feedback_user(%{"end_user_ref" => ref} = item, %{hash_end_user: true})
       when not is_nil(ref) do
    Map.put(item, "end_user_ref", Payload.sha256_hex(to_string(ref)))
  end

  defp hash_feedback_user(item, _config), do: item

  @doc """
  Instrumentation wrapper. See `PromptOnSDK.Generation` for the contract. Returns `fun`'s value
  as-is.
  """
  @spec with_generation(Resolution.t(), map() | keyword(), (-> term())) :: term()
  def with_generation(%Resolution{} = r, meta, fun) when is_function(fun, 0) do
    Generation.with_generation(r, meta, fun)
  end

  defp dispatch(_lane, message, _item, %{mode: :test}) do
    send(self(), message)
    :ok
  end

  defp dispatch(lane, _message, item, _config) do
    case Buffer.enqueue(lane, item) do
      :ok ->
        :ok

      {:error, :not_running} ->
        warn_no_buffer(lane)

        PromptOnSDK.Telemetry.execute(PromptOnSDK.Telemetry.log_dropped(), %{count: 1}, %{
          reason: :no_buffer,
          lane: lane
        })

        :ok
    end
  end

  defp warn_no_buffer(lane) do
    now = System.monotonic_time(:millisecond)
    last = :persistent_term.get(@no_buffer_warn_key, nil)

    if is_nil(last) or now - last >= @warn_interval do
      :persistent_term.put(@no_buffer_warn_key, now)

      Logger.warning(
        "[PromptOn] #{lane} dropped: PromptOnSDK.Buffer is not running (add {PromptOnSDK, []} to your supervision tree)"
      )
    end
  end

  defp put_defaults(gen) do
    gen
    |> Map.put_new_lazy("id", &UUIDv7.generate/0)
    |> Map.put_new_lazy("started_at", fn -> DateTime.to_iso8601(DateTime.utc_now()) end)
    |> Map.put_new("sdk", %{"name" => "prompton_sdk", "version" => @version})
  end

  defp snapshot_policy(nil), do: nil

  defp snapshot_policy(use_case_key) do
    case Store.get() do
      nil -> nil
      entry -> get_in(entry.data.use_cases, [to_string(use_case_key), :payload_policy])
    end
  end

  # Recursively normalizes atom keys to strings (structs excluded). Values are left untouched.
  defp deep_stringify(%{__struct__: _} = struct), do: struct

  defp deep_stringify(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {stringify_key(k), deep_stringify(v)} end)
  end

  defp deep_stringify(list) when is_list(list), do: Enum.map(list, &deep_stringify/1)
  defp deep_stringify(other), do: other

  defp stringify_key(k) when is_binary(k), do: k
  defp stringify_key(k) when is_atom(k), do: Atom.to_string(k)
  defp stringify_key(k), do: to_string(k)

  # ---------------------------------------------------------------------------
  # snapshot

  @doc """
  `%{etag, last_modified, source, fetched_at, stale?, age_seconds}`. Without a snapshot:
  `source: :none, stale?: true`.
  """
  @spec snapshot_info() :: map()
  def snapshot_info, do: Snapshot.info()

  @doc """
  Synchronous reload (the counterpart of HeyDiary's Registry.reload). `:live` fetches from the
  remote; `:offline` reloads from file.
  """
  @spec refresh() :: :ok | {:error, term()}
  def refresh, do: Snapshot.refresh()
end
