# PromptOnSDK

PromptOn Elixir SDK — resolve which model/prompt/params to use for a use case, render the prompt,
call the LLM **yourself**, and log the generation. Thin by design (§7.1): PromptOn never sits in the
request path, so an outage costs you nothing but fresher config.

```
resolve(use_case, prompt: "ko") ──▶ %Resolution{model, params, messages, deployment_id, prompt, …}
render(resolution, vars) ─▶ messages
with_generation(resolution, meta, fn -> call the provider end) ─▶ generation logged asynchronously
```

## Installation

The hex package is not published yet, so depend on it by git:

```elixir
def deps do
  [{:prompton_sdk, git: "https://github.com/polimo-dev/prompton-elixir.git", branch: "main"}]
end
```

Once published, the hex line will be:

```elixir
def deps do
  [{:prompton_sdk, "~> 0.1"}]
end
```

## Configuration

```elixir
# config/runtime.exs
config :prompton_sdk,
  api_key: System.fetch_env!("PTN_API_KEY"),          # ptn_<project>_… — a project key
  environment: "production",                               # which environment this app reads (default)
  base_url: "https://prompton.example/api/v1",
  poll_interval: :timer.seconds(30),                       # ETag polling
  disk_cache: "/var/lib/myapp/prompton_snapshot.json",     # nil disables (k8s: emptyDir volume)
  bundle: {:file, Application.app_dir(:myapp, "priv/prompton/snapshot.json")},  # last-resort fallback
  log: [flush_interval: 2_000, flush_size: 100, flush_bytes: 1_000_000, max_buffer: 10_000,
        redact: &MyApp.AI.Redact.call/1],
  http: [receive_timeout: 5_000],                          # Req options
  mode: :live                                              # :live | :test | :offline
```

| key | default | notes |
|---|---|---|
| `api_key` | `nil` | `ptn_<project_slug>_…`; without it no remote calls are made |
| `environment` | `"production"` | sent as `GET /snapshot?environment=…` and used as the disk/bundle guard |
| `base_url` | `nil` | trailing `/` trimmed |
| `poll_interval` | 30 s | also the base of the failure backoff (×2 up to 5 min) |
| `disk_cache` | `nil` | atomic tmp→rename; sidecar `<path>.meta.json` holds ETag / Last-Modified |
| `bundle` | `nil` | `{:file, path}` produced by `mix prompton.export` |
| `log` | see above | `redact` is `fn generation_map -> map`, applied last |
| `http` | `[receive_timeout: 5_000]` | passed to `Req.new/1` (`plug:`/`adapter:` for tests) |
| `mode` | `:live` | `:test` = no HTTP, logs go to the caller; `:offline` = disk/bundle only |
| `hash_end_user` | `false` | send `sha256(end_user_ref)` instead of the raw ref |
| `client` | `PromptOnSDK.Client.Req` | any `PromptOnSDK.Client` implementation |

Add the SDK to your supervision tree after your Repo/PubSub and before Oban / the Endpoint:

```elixir
children = [
  MyApp.Repo,
  {PromptOnSDK, []},          # PromptOnSDK.Supervisor: Snapshot → TaskSupervisor → Buffer (rest_for_one)
  Oban,
  MyAppWeb.Endpoint
]
```

Options given here override the application env (`{PromptOnSDK, mode: :offline}`).

## Fallback chain (§7.3)

```
boot:  init loads disk cache, then bundle (synchronously, if present, valid and same environment)
       handle_continue fetches GET /snapshot (3 s) — boot is never blocked
         200  → persistent_term + disk cache + sidecar          source: :remote
         fail → keep disk/bundle, poll in the background        source: :disk | :bundle  (stale telemetry with age)
         nothing at all → resolve returns {:error, :not_ready}  source: :none
poll:  If-None-Match every poll_interval; 304 = no-op; 200 = swap; failures back off 30 s → 5 min
```

The disk cache and bundle are refused with a warning when their `environment` differs from the configured
`environment` (a `staging` app must not boot on a `production` bundle). `PromptOnSDK.snapshot_info/0` reports
`%{etag, last_modified, source, fetched_at, stale?, age_seconds}`; `PromptOnSDK.refresh/0` re-fetches synchronously.

## Usage (HeyDiary-style Oban worker)

```elixir
defmodule MyApp.Workers.DiaryGeneration do
  use Oban.Worker

  @impl true
  def perform(%Oban.Job{id: job_id, attempt: attempt, args: %{"user_id" => user_id} = args}) do
    with {:ok, r} <- PromptOnSDK.resolve("diary_generation", prompt: args["language"] || "default"),
         vars = %{transcriptions: args["transcriptions"], mode: args["mode"]},
         {:ok, msgs} <- PromptOnSDK.render(r, vars) do
      PromptOnSDK.with_generation(
        r,
        %{end_user_ref: user_id, trace_id: "oban:#{job_id}", sequence: attempt,
          input_messages: msgs, variables: vars, context: %{language: args["language"], plan: args["plan"]},
          metadata: %{job_id: job_id, attempt: attempt}},
        fn ->
          body = PromptOnSDK.OpenRouter.request_body(r, msgs)      # model/provider.only/params + usage.include

          case Req.post(openrouter_url(), auth: {:bearer, key()}, json: body, receive_timeout: 300_000, retry: false) do
            {:ok, %{status: 200, body: resp}} ->
              outcome = PromptOnSDK.OpenRouter.outcome(resp)       # content, tokens, cost (BYOK-aware), stop_kind

              case parse_diary(outcome.content) do
                {:ok, diary} -> {:ok, %{outcome | result: diary}}
                {:error, e}  -> {:error, %{kind: :parse, message: e}, outcome}   # 3-tuple keeps usage/output
              end

            {:ok, %{status: s, body: b}} -> {:error, %{kind: http_kind(s), status: s, message: inspect(b)}}
            {:error, e}                  -> {:error, %{kind: :transport, message: inspect(e)}}
          end
        end
      )
      |> case do
        {:ok, %{result: diary}} -> save(diary)
        {:error, _} = err -> err
        {:error, _, _} -> {:cancel, :parse}
      end
    else
      {:error, :not_ready} -> {:snooze, 5}
      {:error, :unknown_use_case} -> {:cancel, :unknown_use_case}
      {:error, :unknown_prompt} -> {:cancel, :unknown_prompt}
      {:error, :unresolved} -> {:error, :unresolved}
      {:error, {:missing_variable, name}} -> {:cancel, {:missing_variable, name}}
    end
  end
end
```

`with_generation/3` measures `started_at`/`latency_ms`, interprets the return value
(`{:ok, outcome}` → `status ok`; `{:error, error}` → `status error`; `{:error, error, outcome}` → error **with**
usage/output; exception → `error/app` and re-raise), builds the §6.4 generation map and enqueues it. It always
returns what your function returned. `render/2` is pure — pass the same `variables` to `with_generation` if
you want them logged. Request context (language, plan, whatever you tag calls with) is a **log-only**
passthrough now: hand it to `with_generation` as `meta.context`.

Other entry points: `PromptOnSDK.prompt_names/1` (which prompt names the live deployment pins),
`PromptOnSDK.generation_id/0` (pre-issued UUIDv7 for later scoring), `PromptOnSDK.log/1` (manual, e.g. after
streaming), `PromptOnSDK.feedback/1` (`%{generation_id, kind, value, …}`), `PromptOnSDK.Generic.outcome/1`
(Groq/embeddings).

## Snapshot v3 — a deployment is a pin, not a router

The SDK reads **schema v3 only**. A deployment revision no longer routes: no rules, no conditions, no targets,
no weights, no A/B, no context dimensions. One revision is **one model** plus **one pinned prompt version per
prompt name**:

```json
"deployments": {
  "diary_generation": {
    "id": "…", "revision": 7,
    "model_id": "…", "params": {"temperature": 0.5}, "provider_options": {"only": ["Anthropic"]},
    "prompt_pins": {"default": "<prompt version id>", "ko": "<prompt version id>"}
  }
}
```

Selection at request time is the prompt name and nothing else:

```elixir
{:ok, r} = PromptOnSDK.resolve("diary_generation")                  # pin "default"
{:ok, r} = PromptOnSDK.resolve("diary_generation", prompt: "ko")    # pin "ko"
{:ok, names} = PromptOnSDK.prompt_names("diary_generation")         # ["default", "ko"]
```

A name the deployment does not pin is `{:error, :unknown_prompt}` — the SDK never falls back to `"default"`
silently, because shipping English to a `"ko"` request is worse than an error.

| | v2 (deleted) | v3 |
|---|---|---|
| Config unit | `deployments[key].rules[]` with inline targets | `deployments[key]` = model + `prompt_pins` |
| Request-time input | `ctx` map + `target_id` + `subject_key` | `prompt:` name |
| A/B split | weighted targets | — (deploy a revision, roll back if it is worse) |
| `%Resolution{}` identity | `target_id`, `rule_id`, `deployment_id`, `deployment_revision` | `deployment_id`, `deployment_revision`, `prompt`, `prompt_version_id` |
| Logged generation keys | `+ rule_id`, `target_id` | `deployment_id`, `deployment_revision`, `prompt`, `prompt_version_id` |

Everything else is unchanged: `default_params ⊕ deployment params`, `model.provider_options ⊕ deployment
provider_options`, templates, ETag polling, disk/bundle fallback, monitoring-log envelope. v1/v2 snapshots (a stale disk
cache or an old repo bundle) are refused with `{:error, {:unsupported_schema_version, n}}` and the SDK keeps
polling for a v3 one.

## Logging pipeline

`log/1` never raises. Before enqueueing, the SDK applies the use case's `payload_policy` from the snapshot
(`PromptOnSDK.Payload`): string `input`/`output` are always wrapped as objects (`{"text": …}` /
`{"content": …}`); `mode :none` drops input/output; `:hash` replaces them with the pre-hashed wrapper
`{"sha256": hex, "bytes": n, "hashed": true}` (the server stores the hash and never sees the text); `:full`
truncates to the same limits the server re-checks (message content ≤ `max_bytes/8` bytes, `messages` JSON ≤
`max_bytes`, output content ≤ `max_bytes/4`, `tool_calls`/`variables` JSON ≤ `max_bytes/4`; head+tail kept,
middle messages stubbed or dropped). `sample_rate` is decided by
`first4bytes(sha256(id)) rem 10_000 < round(rate × 10_000)` — the server uses the same bucket — and errors
and `stop_kind length` are always kept; `redact` runs last.

`PromptOnSDK.Buffer` batches (100 items / 1 MB / 2 s; each request ≤200 items **and** ≤4 MB encoded; 2
concurrent sends), retries 5xx and transport errors with 1 s→60 s backoff, honours `Retry-After` on 429 and
503, splits a batch in half on 413 (a single item over 4 MB is dropped with `[:prompton, :log, :dropped]`
reason `:too_large`), drops on other 4xx, drops the oldest above `max_buffer`, and drains synchronously
(≤5 s) on shutdown.

## Telemetry

`[:prompton, :snapshot, :updated | :stale | :fetch_error]`, `[:prompton, :resolve, :stop]`,
`[:prompton, :generation, :start | :stop | :exception]`, `[:prompton, :log, :flush | :dropped | :error]` —
see `PromptOnSDK.Telemetry` for measurements/metadata. Attach them to LiveDashboard/PromEx to watch your LLM
traffic locally even when PromptOn is down.

## Test mode

```elixir
# config/test.exs
config :prompton_sdk, mode: :test        # no HTTP; no supervisor needed

# test
import PromptOnSDK.Test

setup do
  PromptOnSDK.Test.stub("diary_generation", %{
    model: "openai/gpt-5-mini",
    messages: [%{role: "system", content: "You are a diary writer."}, %{role: "user", content: "{{ text }}"}],
    params: %{temperature: 0.5}
  })
  on_exit(&PromptOnSDK.Test.clear/0)
end

test "logs a generation" do
  assert :ok = perform_job(MyApp.Workers.DiaryGeneration, %{...})     # runs in the test process
  gen = assert_logged(%{"use_case" => "diary_generation", "status" => "ok"})
  assert gen["usage"]["input_tokens"] == 100
end
```

`PromptOnSDK.Test.put_snapshot/1` accepts a full snapshot map, `{:file, path}` or `%SnapshotData{}`.
In `:test` mode `log/1` sends `{:prompton_generation, gen}` (and `feedback/1` `{:prompton_feedback, map}`)
to the calling process instead of the buffer.

## Bundle export

```
mix prompton.export --out priv/prompton/snapshot.json [--base-url URL] [--api-key KEY]
```

Fetches `GET /snapshot` (flags → `PTN_BASE_URL`/`PTN_API_KEY` env → app config) and writes the JSON
plus `<out>.meta.json` (etag, last_modified, environment, exported_at). Run it in CI on every build and commit
the result; on failure the task exits non-zero and leaves the existing file untouched.

## Modules

| Layer | Modules |
|---|---|
| Pure core (shared with the server) | `SnapshotData`, `Resolver`, `Resolution`, `Template`, `StopKind`, `Params` |
| Runtime | `Supervisor`, `Config`, `Snapshot`, `Snapshot.Store`, `Buffer`, `Client`, `Client.Req`, `Payload`, `Generation`, `UUIDv7`, `Telemetry` |
| Adapters & tooling | `OpenRouter`, `Generic`, `Test`, `Mix.Tasks.Prompton.Export` |

## Conformance suite

`conformance/` holds the cross-language contract every other PromptOn SDK (Python, Node.js, Go,
Ruby, Java, Kotlin, Rust) must reproduce: template rendering, resolution, monitoring-log
truncation, `stop_kind` normalisation and golden generation records, as JSON files with expected
values. They are generated by running this SDK (`mix run scripts/gen_conformance.exs`) and replayed
through it by `test/prompton_sdk/conformance_test.exs`. See
[conformance/README.md](conformance/README.md) for the exact semantics each file encodes.

## License

Copyright 2026 Polimo

Licensed under the Apache License, Version 2.0 (the "License"); you may not use this SDK except in
compliance with the License. You may obtain a copy of the License at
http://www.apache.org/licenses/LICENSE-2.0 — see [LICENSE](LICENSE) in this directory.

This SDK (`sdk/elixir`) is licensed **separately** from the rest of the
[polimo-dev/prompton](https://github.com/polimo-dev/prompton) repository, which is under the
Functional Source License (FSL-1.1-ALv2). Apps depending on `prompton_sdk` take only Apache-2.0 code.

PromptOn is a trademark of Polimo. The license does not grant permission to use the PromptOn name or
logo; forks and derived services must use a different name.
