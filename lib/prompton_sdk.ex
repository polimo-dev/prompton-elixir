defmodule PromptOnSDK do
  @moduledoc """
  Top-level module of the PromptOn Elixir SDK: the public API (§7.4).

  The package is split into two layers.

  * **Pure core** (no processes, no HTTP): `PromptOnSDK.PromptDocument`,
    `PromptOnSDK.Template`, `PromptOnSDK.StopKind`, `PromptOnSDK.Params`.
  * **Runtime**: `PromptOnSDK.Supervisor` (loader/poller,
    `PromptOnSDK.TaskSupervisor`, the `PromptOnSDK.Buffer` batcher), `PromptOnSDK.Config`,
    `PromptOnSDK.Client` (+ `Client.Req`), `PromptOnSDK.Payload` (payload policy),
    `PromptOnSDK.Prompt` (`messages/3`, `text/3`, `track/3`), `PromptOnSDK.Result`, the
    `PromptOnSDK.OpenRouter` request adapter, `PromptOnSDK.UUIDv7`, the test mode
    `PromptOnSDK.Test`, and `mix prompton.export`.

  ## Getting started

      # config/runtime.exs
      config :prompton_sdk,
        api_key: System.fetch_env!("PTN_API_KEY"),
        base_url: "https://prompton.example/api/v1",
        disk_cache: "/var/lib/myapp/prompton_prompts.production.json",
        bundle: {:file, Application.app_dir(:myapp, "priv/prompton/prompts.production.json")}

      # application.ex
      children = [MyApp.Repo, {PromptOnSDK, []}, Oban, MyAppWeb.Endpoint]

  ## Call flow

      question = "My invoice shows two charges this month."

      {:ok, prompt} = PromptOnSDK.prompt("support_reply")
      {:ok, msgs} = PromptOnSDK.messages(prompt, %{question: question, language: "ko", plan: "pro"})

      PromptOnSDK.track(prompt, %{end_user_ref: "cust_8f31", trace_id: "ticket:88213",
                                    input_messages: msgs,
                                    variables: %{question: question, language: "ko", plan: "pro"},
                                    context: %{language: "ko", plan: "pro"}}, fn ->
        body = PromptOnSDK.OpenRouter.request_body(prompt, msgs)
        case Req.post(url, json: body) do
          {:ok, %{status: 200, body: resp}} -> {:ok, PromptOnSDK.Result.from_openai(resp)}
          {:ok, %{status: s, body: b}}      -> {:error, %{kind: :http_5xx, status: s, message: inspect(b)}}
          {:error, e}                       -> {:error, %{kind: :transport, message: inspect(e)}}
        end
      end)

  ## Errors (§7.7)

  * `prompt/2`: `{:error, :not_ready}` (no prompt document: remote, disk, and bundle all failed),
    `{:error, :unknown_prompt}`, `{:error, :unresolved}` (no deployment),
    `{:error, :unknown_template}` (the deployment has no template with that name)
  * `messages/3` / `text/3`: `{:error, reason}` where `reason` is `:wrong_kind`,
    `:no_template`, `{:missing_variable, name}`, `{:render, reason}`, or `{:parse, reason}`
  * `log/1`, `feedback/1`: **never raise** (`:ok`).

  ## Rendering and `variables`

  `messages/3` and `text/3` return only provider input and do not mutate the immutable Prompt
  struct. To keep named-prompt evidence aligned in the common flow, a successful
  `messages/3`/`text/3` call with `template: "name"` stores a process-local, one-shot prompt
  selection. The next `track/3` for the same prompt consumes and clears it, so the log records the
  matching `template`/`prompt_version_id` even when track meta omits `template:`. Render failures,
  default renders, and explicit `track(..., template: ...)` clear or override the stored selection.
  To record the pre-render variable values in the log, pass the same map as `meta.variables` of
  `track/3` (see the example above). Request context (free-form tags such as language or plan) is
  passed the same way, as `meta.context`; prompt selection no longer looks at the context (ADR
  0007, revised 2026-09-01).
  """

  require Logger

  alias PromptOnSDK.{
    Buffer,
    Config,
    Payload,
    Prompt,
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
  # prompt / messages/text / options

  @doc """
  Prompt key -> `%PromptOnSDK.Prompt{}`. `opts`: `template:` (the template name to pick, default
  `"default"`). The prompt document is read from `:persistent_term`, so no process call is involved.
  """
  @spec prompt(String.t() | atom(), keyword()) ::
          {:ok, Prompt.t()}
          | {:error, :not_ready | :unknown_prompt | :unresolved | :unknown_template}
  def prompt(prompt_key, opts \\ []) do
    with {:ok, r} <- do_resolve(prompt_key, opts) do
      template_names =
        case template_names(prompt_key) do
          {:ok, names} -> names
          {:error, _reason} -> []
        end

      {:ok, Prompt.from_resolution(r, template_names)}
    end
  end

  @doc """
  Prepare the deployed provider request. Returns its explicit API, POST method, origin-relative
  path, and rendered JSON body. The application supplies provider credentials and sends it.
  Schema v5 snapshots remain readable but return `{:error, :missing_request_metadata}` here.
  `opts` supports `template:`, `params:`, and `provider_options:` overrides. Decisions also accept
  `session_id:`, `trace:`, and `user:` metadata. Protected body fields cannot be overridden.
  """
  @spec request(Prompt.t() | Resolution.t(), map() | nil, keyword()) ::
          {:ok, PromptOnSDK.ProviderRequest.t()} | {:error, term()}
  def request(prompt, variables, opts \\ [])
  def request(%Prompt{} = prompt, variables, opts), do: Prompt.request(prompt, variables, opts)

  def request(%Resolution{} = resolution, variables, opts),
    do: resolution |> Prompt.from_resolution() |> Prompt.request(variables, opts)

  @doc "Render a chat prompt into provider messages."
  @spec messages(Prompt.t(), map() | nil, keyword()) ::
          {:ok, [map()]} | {:error, :wrong_kind | :no_template | Template.render_error()}
  def messages(%Prompt{} = prompt, variables, opts \\ []),
    do: Prompt.messages(prompt, variables, opts)

  @doc "Render a text prompt into a single provider input string."
  @spec text(Prompt.t(), map() | nil, keyword()) ::
          {:ok, String.t()} | {:error, :wrong_kind | :no_template | Template.render_error()}
  def text(%Prompt{} = prompt, variables, opts \\ []),
    do: Prompt.text(prompt, variables, opts)

  @doc "Wrap a provider call and enqueue one monitoring log."
  @spec track(Prompt.t(), keyword() | map(), (-> term())) :: term()
  def track(%Prompt{} = prompt, meta \\ [], fun) when is_function(fun, 0),
    do: Prompt.track(prompt, meta, fun)

  defp do_resolve(prompt_key, opts) do
    t0 = System.monotonic_time()

    result =
      case Store.get() do
        nil ->
          {:error, :not_ready}

        entry ->
          Resolver.resolve(entry.data, prompt_key,
            template: opts[:template],
            source: entry.source,
            etag: entry.etag
          )
      end

    emit_resolve(prompt_key, result, t0)
    result
  end

  defp emit_resolve(prompt_key, result, t0) do
    meta =
      case result do
        {:ok, r} ->
          %{
            source: r.source,
            template: r.template,
            deployment_id: r.deployment_id,
            deployment_revision: r.deployment_revision,
            result: :ok
          }

        {:error, reason} ->
          %{
            source: nil,
            template: nil,
            deployment_id: nil,
            deployment_revision: nil,
            result: reason
          }
      end

    PromptOnSDK.Telemetry.execute(
      PromptOnSDK.Telemetry.prompt_stop(),
      %{duration: System.monotonic_time() - t0},
      Map.put(meta, :prompt_key, to_string(prompt_key))
    )
  end

  @doc """
  The **list of template names** (sorted) pinned by this Prompt's live deployment. `{:ok, []}` when
  there is no deployment. This list is exactly the set of values accepted by `prompt/2`'s
  `template:`.
  """
  @spec template_names(String.t() | atom()) ::
          {:ok, [String.t()]} | {:error, :not_ready | :unknown_prompt}
  def template_names(prompt_key) do
    case Store.get() do
      nil -> {:error, :not_ready}
      entry -> Resolver.template_names(entry.data, prompt_key)
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
  * Applies the payload policy (`PromptOnSDK.Payload`): `opts[:policy]` (the Prompt's
    `payload_policy`) or the current prompt document's policy for that Prompt, else
    `config.payload_defaults`.
  * With `mode: :test`, sends `{:prompton_log, log}` to the **calling process** instead of
    the Buffer (`PromptOnSDK.Test.assert_logged/1`).
  * If the Buffer is not running, drops the item and warns (once per minute).
  """
  @spec log(map(), keyword()) :: :ok
  def log(gen, opts \\ []) do
    config = Config.get()
    gen = gen |> deep_stringify() |> put_defaults()
    policy = Keyword.get(opts, :policy) || snapshot_policy(gen["prompt_key"])
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

  defp snapshot_policy(prompt_key) do
    case Store.get() do
      nil -> nil
      entry -> get_in(entry.data.prompts, [to_string(prompt_key), :payload_policy])
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
  # prompt document

  @doc """
  `%{etag, last_modified, source, fetched_at, stale?, age_seconds}`. Without a prompt document:
  `source: :none, stale?: true`.
  """
  @spec prompt_document_info() :: map()
  def prompt_document_info, do: Snapshot.info()

  @doc """
  Synchronous reload of the prompt document. `:live` fetches from the remote; `:offline` reloads
  from file.
  """
  @spec refresh_prompt_document() :: :ok | {:error, term()}
  def refresh_prompt_document, do: Snapshot.refresh_prompt_document()
end
