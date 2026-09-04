defmodule PromptOnSDK do
  @moduledoc """
  Top-level module of the PromptOn Elixir SDK: the public API (§7.4).

  The package is split into two layers.

  * **Pure core** (no processes, no HTTP): `PromptOnSDK.UseCaseDocument`,
    `PromptOnSDK.Template`, `PromptOnSDK.StopKind`, `PromptOnSDK.Params`.
  * **Runtime**: `PromptOnSDK.Supervisor` (loader/poller,
    `PromptOnSDK.TaskSupervisor`, the `PromptOnSDK.Buffer` batcher), `PromptOnSDK.Config`,
    `PromptOnSDK.Client` (+ `Client.Req`), `PromptOnSDK.Payload` (payload policy),
    `PromptOnSDK.UseCase` (`messages/3`, `text/3`, `track/3`), `PromptOnSDK.Result`, the
    `PromptOnSDK.OpenRouter` request adapter, `PromptOnSDK.UUIDv7`, the test mode
    `PromptOnSDK.Test`, and `mix prompton.export`.

  ## Getting started

      # config/runtime.exs
      config :prompton_sdk,
        api_key: System.fetch_env!("PTN_API_KEY"),
        base_url: "https://prompton.example/api/v1",
        disk_cache: "/var/lib/myapp/prompton_use-cases.production.json",
        bundle: {:file, Application.app_dir(:myapp, "priv/prompton/use-cases.production.json")}

      # application.ex
      children = [MyApp.Repo, {PromptOnSDK, []}, Oban, MyAppWeb.Endpoint]

  ## Call flow

      question = "My invoice shows two charges this month."

      {:ok, use_case} = PromptOnSDK.use_case("support_reply", prompt: "ko")
      {:ok, msgs} = PromptOnSDK.messages(use_case, %{question: question, plan: "pro"})

      PromptOnSDK.track(use_case, %{end_user_ref: "cust_8f31", trace_id: "ticket:88213",
                                    input_messages: msgs,
                                    variables: %{question: question, plan: "pro"},
                                    context: %{language: "ko", plan: "pro"}}, fn ->
        body = PromptOnSDK.OpenRouter.request_body(use_case, msgs)
        case Req.post(url, json: body) do
          {:ok, %{status: 200, body: resp}} -> {:ok, PromptOnSDK.Result.from_openai(resp)}
          {:ok, %{status: s, body: b}}      -> {:error, %{kind: :http_5xx, status: s, message: inspect(b)}}
          {:error, e}                       -> {:error, %{kind: :transport, message: inspect(e)}}
        end
      end)

  ## Errors (§7.7)

  * `use_case/2`: `{:error, :not_ready}` (no use-case document: remote, disk, and bundle all failed),
    `{:error, :unknown_use_case}`, `{:error, :unresolved}` (no deployment),
    `{:error, :unknown_prompt}` (the deployment has no prompt with that name)
  * `messages/3` / `text/3`: `{:error, reason}` where `reason` is `:wrong_kind`,
    `:no_template`, `{:missing_variable, name}`, `{:render, reason}`, or `{:parse, reason}`
  * `log/1`, `feedback/1`: **never raise** (`:ok`).

  ## Rendering and `variables`

  `messages/3` and `text/3` return only provider input and do not mutate the immutable UseCase
  struct. To keep named-prompt evidence aligned in the common flow, a successful
  `messages/3`/`text/3` call with `prompt: "name"` stores a process-local, one-shot prompt
  selection. The next `track/3` for the same use case consumes and clears it, so the log records the
  matching `prompt`/`prompt_version_id` even when track meta omits `prompt:`. Render failures,
  default renders, and explicit `track(..., prompt: ...)` clear or override the stored selection.
  To record the pre-render variable values in the log, pass the same map as `meta.variables` of
  `track/3` (see the example above). Request context (free-form tags such as language or plan) is
  passed the same way, as `meta.context`; use case selection no longer looks at the context (ADR
  0007, revised 2026-09-01).
  """

  require Logger

  alias PromptOnSDK.{
    Buffer,
    Config,
    Payload,
    Resolver,
    Snapshot,
    Template,
    UseCase,
    UUIDv7
  }

  alias PromptOnSDK.Snapshot.Store

  @version Mix.Project.config()[:version]
  @no_buffer_warn_key {PromptOnSDK, :no_buffer_warned_at}
  @warn_interval 60_000

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
  # use case / messages/text / options

  @doc """
  Use case key -> `%PromptOnSDK.UseCase{}`. `opts`: `prompt:` (the prompt name to pick, default
  `"default"`). The use-case document is read from `:persistent_term`, so no process call is involved.
  """
  @spec use_case(String.t() | atom(), keyword()) ::
          {:ok, UseCase.t()}
          | {:error, :not_ready | :unknown_use_case | :unresolved | :unknown_prompt}
  def use_case(use_case_key, opts \\ []) do
    with {:ok, r} <- do_resolve(use_case_key, opts) do
      prompt_names =
        case prompt_names(use_case_key) do
          {:ok, names} -> names
          {:error, _reason} -> []
        end

      {:ok, UseCase.from_resolution(r, prompt_names)}
    end
  end

  @doc "Render a chat use case into provider messages."
  @spec messages(UseCase.t(), map() | nil, keyword()) ::
          {:ok, [map()]} | {:error, :wrong_kind | :no_template | Template.render_error()}
  def messages(%UseCase{} = use_case, variables, opts \\ []),
    do: UseCase.messages(use_case, variables, opts)

  @doc "Render a text use case into a single provider input string."
  @spec text(UseCase.t(), map() | nil, keyword()) ::
          {:ok, String.t()} | {:error, :wrong_kind | :no_template | Template.render_error()}
  def text(%UseCase{} = use_case, variables, opts \\ []),
    do: UseCase.text(use_case, variables, opts)

  @doc "Wrap a provider call and enqueue one monitoring log."
  @spec track(UseCase.t(), keyword() | map(), (-> term())) :: term()
  def track(%UseCase{} = use_case, meta \\ [], fun) when is_function(fun, 0),
    do: UseCase.track(use_case, meta, fun)

  defp do_resolve(use_case_key, opts) do
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
      PromptOnSDK.Telemetry.use_case_stop(),
      %{duration: System.monotonic_time() - t0},
      Map.put(meta, :use_case, to_string(use_case_key))
    )
  end

  @doc """
  The **list of prompt names** (sorted) pinned by this UseCase's live deployment. `{:ok, []}` when
  there is no deployment. This list is exactly the set of values accepted by `use_case/2`'s
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

  @doc "Pre-issues a UUIDv7 log id (for later scoring and for storing the app's own row)."
  @spec log_id() :: String.t()
  def log_id, do: UUIDv7.generate()

  @doc """
  Enqueues one log asynchronously (§6.4 format, atom or string keys). **Never raises.**

  * Fills in `id`/`started_at`/`sdk` when they are absent.
  * Applies the payload policy (`PromptOnSDK.Payload`): `opts[:policy]` (the UseCase's
    `payload_policy`) or the current use-case document's policy for that UseCase, else
    `config.payload_defaults`.
  * With `mode: :test`, sends `{:prompton_log, log}` to the **calling process** instead of
    the Buffer (`PromptOnSDK.Test.assert_logged/1`).
  * If the Buffer is not running, drops the item and warns (once per minute).
  """
  @spec log(map(), keyword()) :: :ok
  def log(gen, opts \\ []) do
    config = Config.get()
    gen = gen |> deep_stringify() |> put_defaults()
    policy = Keyword.get(opts, :policy) || snapshot_policy(gen["use_case"])
    gen = Payload.apply(gen, policy, config)
    dispatch(:logs, {:prompton_log, gen}, gen, config)
  rescue
    e ->
      Logger.warning("[PromptOn] log/1 dropped a log: #{Exception.message(e)}")
      :ok
  catch
    kind, value ->
      Logger.warning("[PromptOn] log/1 dropped a log: #{inspect({kind, value})}")
      :ok
  end

  @doc """
  One feedback item (§6.5: `log_id`★, `kind`★, `value`, `comment`, `end_user_ref`,
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

    if is_nil(item["log_id"]) or is_nil(item["kind"]) do
      Logger.warning("[PromptOn] feedback/1 dropped: log_id and kind are required")
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
  # use-case document

  @doc """
  `%{etag, last_modified, source, fetched_at, stale?, age_seconds}`. Without a use-case document:
  `source: :none, stale?: true`.
  """
  @spec use_case_document_info() :: map()
  def use_case_document_info, do: Snapshot.info()

  @doc """
  Synchronous reload of the use-case document. `:live` fetches from the remote; `:offline` reloads
  from file.
  """
  @spec refresh_use_case_document() :: :ok | {:error, term()}
  def refresh_use_case_document, do: Snapshot.refresh_use_case_document()
end
