# PromptOnSDK

PromptOn Elixir SDK — fetch the deployed prompt and prepare its provider request,
call the LLM **yourself**, and record a monitoring log. Thin by design (§7.1): PromptOn never sits in the
request path, so an outage costs you nothing but fresher config.

```
prompt(key) ──▶ %Prompt{key, kind, model, params, deployment, template, …}
request(prompt, vars) ─▶ %{api, method: :post, path, body}
track(prompt, meta, fn -> call the provider end) ─▶ log recorded asynchronously
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
  [{:prompton_sdk, "~> 0.3"}]
end
```

## Prepared provider requests

SDK 0.3 reads schema v6 documents and returns the deployed API, origin-relative path and rendered
body. Your app supplies the provider origin and credentials and sends the HTTP request:

```elixir
{:ok, prompt} = PromptOnSDK.prompt("support_route")
{:ok, request} = PromptOnSDK.request(prompt, %{input: "My payment failed"})
{:ok, response} = Req.request(
  method: request.method,
  url: provider_origin <> request.path,
  auth: {:bearer, provider_key},
  json: request.body
)
```

`request.api` is `:chat_completions` or `:decisions`, taken from the deployment metadata rather than
inferred from its model name. The pinned version determines the serving type even after the editor's
type changes. Chat requests render `messages`; Decision requests render native `state` and `questions`
recursively in string values, preserving JSON types, question names and choice labels.

Supported explicit routes are OpenRouter Chat and Decisions, OpenAI Chat, and Groq Chat. Unsupported
providers, missing metadata, API/type mismatches and invalid native questions return an error before
a provider call. Legacy schema v5 documents remain readable by `messages/3` and `text/3`, but cannot
prepare a request. Upgrade the server and cached/bundled document to schema v6 when adopting `request/3`.

Options include `template:`, shallow `params:` and `provider_options:` overrides. Chat omits nil
parameter values; provider options preserve explicit nil as JSON null. Decisions accept only
`session_id`, `trace` and `user` parameters (also available as keyword options); session/user values
must be strings up to 256 characters and trace must be an object. Sampling, tools, streaming and
protected fields such as model/state/questions cannot be injected through Decision params.

For Decisions monitoring, preserve the full answers and native input:

```elixir
PromptOnSDK.track(prompt, %{input_decision: Map.take(request.body, ["state", "questions"])}, fn ->
  with {:ok, response} <- Req.request(method: request.method,
         url: provider_origin <> request.path, auth: {:bearer, provider_key}, json: request.body) do
    PromptOnSDK.Result.from_decisions(response.body)
  end
end)
```

`Result.from_decisions/1` returns `{:ok, result}` or `{:error, :invalid_decisions_response}` and keeps
the full typed answers, probabilities, usage and raw response. Chat adapters remain available.

## Configuration

```elixir
# config/runtime.exs
config :prompton_sdk,
  api_key: System.fetch_env!("PTN_API_KEY"),          # ptn_<project>_… — a project key
  environment: "production",                               # which environment this app reads (default)
  base_url: "https://prompton.example/api/v1",
  poll_interval: :timer.seconds(10),                       # ETag polling
  disk_cache: "/var/lib/myapp/prompton_prompts.production.json",     # nil disables (k8s: emptyDir volume)
  bundle: {:file, Application.app_dir(:myapp, "priv/prompton/prompts.production.json")},  # last-resort fallback
  log: [flush_interval: 2_000, flush_size: 100, flush_bytes: 1_000_000, max_buffer: 10_000,
        redact: &MyApp.AI.Redact.call/1],
  http: [receive_timeout: 5_000],                          # Req options
  mode: :live                                              # :live | :test | :offline
```

| key | default | notes |
|---|---|---|
| `api_key` | `nil` | `ptn_<project_slug>_…`; without it no remote calls are made |
| `environment` | `"production"` | sent as `GET /prompts?environment=…` and used as the disk/bundle guard |
| `base_url` | `nil` | trailing `/` trimmed |
| `poll_interval` | 10 s | also the base of the failure backoff (×2 up to 5 min) |
| `disk_cache` | `nil` | atomic tmp→rename; sidecar `<path>.meta.json` holds ETag / Last-Modified |
| `bundle` | `nil` | `{:file, path}` produced by `mix prompton.export` |
| `log` | see above | `redact` is `fn log_map -> map`, applied last |
| `http` | `[receive_timeout: 5_000]` | passed to `Req.new/1` (`plug:`/`adapter:` for tests) |
| `mode` | `:live` | `:test` = no HTTP, logs go to the caller; `:offline` = disk/bundle only |
| `hash_end_user` | `false` | send `sha256(end_user_ref)` instead of the raw ref |
| `client` | `PromptOnSDK.Client.Req` | any `PromptOnSDK.Client` implementation |

Add the SDK to your supervision tree after your Repo/PubSub and before Oban / the Endpoint:

```elixir
children = [
  MyApp.Repo,
  {PromptOnSDK, []},          # PromptOnSDK.Supervisor: loader → TaskSupervisor → Buffer (rest_for_one)
  Oban,
  MyAppWeb.Endpoint
]
```

Options given here override the application env (`{PromptOnSDK, mode: :offline}`).

## Fallback chain (§7.3)

```
boot:  init loads disk cache, then bundle (synchronously, if present, valid and same environment)
       handle_continue fetches GET /prompts (3 s) — boot is never blocked
         200  → persistent_term + disk cache + sidecar          source: :remote
         fail → keep disk/bundle, poll in the background        source: :disk | :bundle  (stale telemetry with age)
         nothing at all → prompt returns {:error, :not_ready} source: :none
poll:  If-None-Match every poll_interval; 304 = no-op; 200 = swap; failures back off 10 s → 5 min
```

The disk cache and bundle are refused with a warning when their `environment` differs from the configured
`environment` (a `staging` app must not boot on a `production` bundle). `PromptOnSDK.prompt_document_info/0` reports
`%{etag, last_modified, source, fetched_at, stale?, age_seconds}`; `PromptOnSDK.refresh_prompt_document/0`
re-fetches synchronously.

## Usage (Oban worker)

```elixir
defmodule MyApp.Workers.SupportReply do
  use Oban.Worker

  @impl true
  def perform(%Oban.Job{id: job_id, attempt: attempt, args: %{"customer_ref" => customer_ref} = args}) do
    with {:ok, r} <- PromptOnSDK.prompt("support_reply"),
         vars = %{question: args["question"], language: args["language"] || "en", plan: args["plan"]},
         {:ok, msgs} <- PromptOnSDK.messages(r, vars) do
      PromptOnSDK.track(
        r,
        %{end_user_ref: customer_ref, trace_id: "ticket:#{args["ticket_id"]}", sequence: attempt,
          input_messages: msgs, variables: vars, context: %{language: args["language"], plan: args["plan"]},
          metadata: %{ticket_id: args["ticket_id"], job_id: job_id, attempt: attempt}},
        fn ->
          body = PromptOnSDK.OpenRouter.request_body(r, msgs)      # model/provider.only/params + usage.include

          case Req.post(openrouter_url(), auth: {:bearer, key()}, json: body, receive_timeout: 300_000, retry: false) do
            {:ok, %{status: 200, body: resp}} ->
              result = PromptOnSDK.Result.from_openai(resp)        # content, tokens, cost (BYOK-aware), stop_kind

              case parse_reply(result.content) do
                {:ok, reply} -> {:ok, %{result | result: reply}}
                {:error, e}  -> {:error, %{kind: :parse, message: e}, result}    # 3-tuple keeps usage/output
              end

            {:ok, %{status: s, body: b}} -> {:error, %{kind: http_kind(s), status: s, message: inspect(b)}}
            {:error, e}                  -> {:error, %{kind: :transport, message: inspect(e)}}
          end
        end
      )
      |> case do
        {:ok, %{result: reply}} -> send_reply(customer_ref, reply)
        {:error, _} = err -> err
        {:error, _, _} -> {:cancel, :parse}
      end
    else
      {:error, :not_ready} -> {:snooze, 5}
      {:error, :unknown_prompt} -> {:cancel, :unknown_prompt}
      {:error, :unknown_template} -> {:cancel, :unknown_template}
      {:error, :unresolved} -> {:error, :unresolved}
      {:error, {:missing_variable, name}} -> {:cancel, {:missing_variable, name}}
    end
  end
end
```

`track/3` measures `started_at`/`latency_ms`, interprets the return value
(`{:ok, result}` → `status ok`; `{:error, error}` → `status error`; `{:error, error, result}` → error **with**
usage/output; exception → `error/app` and re-raise), builds the §6.4 log map and enqueues it. It always
returns what your function returned. Pass the same `variables` to `track` if you want them logged.
When `messages/3` or `text/3` renders with `template: "name"`, the SDK stores that template choice in
process-local, one-shot state so the next `track/3` for the same prompt records matching
`template`/`prompt_version_id` evidence even if `track` meta omits `template:`. `track/3` consumes and
clears that state; render failures, default renders, and explicit `track(..., template: ...)` also
clear/override it. Request context (language, plan, whatever you tag calls with) is a
**log-only** passthrough now: hand it to `track` as `meta.context`.

Other entry points: `PromptOnSDK.template_names/1` (which template names the live deployment pins),
`PromptOnSDK.log_id/0` (pre-issued UUIDv7 for later scoring), `PromptOnSDK.log/1` (manual, e.g. after
streaming), `PromptOnSDK.feedback/1` (`%{log_id, kind, value, …}`),
`PromptOnSDK.Result.from_openai/1`, `PromptOnSDK.Result.from_anthropic/1`, and
`PromptOnSDK.Result.from_generic/1` for provider/application result normalization.

## Prompt document v5 — a deployment is a pin, not a router

The SDK reads **schema v6 and legacy v5**; prepared requests require v6 metadata. A deployment revision no longer routes: no rules, no conditions, no targets,
no weights, no A/B, no context dimensions. One revision is **one model** plus **one pinned template version per
template name**:

```json
"deployments": {
  "support_reply": {
    "id": "…", "revision": 7,
    "model_id": "…", "params": {"temperature": 0.3}, "provider_options": {"only": ["OpenAI"]},
    "template_pins": {"default": "<prompt version id>", "ko": "<prompt version id>"}
  }
}
```

Selection at request time is the template name and nothing else:

```elixir
{:ok, r} = PromptOnSDK.prompt("support_reply")                  # pin "default"
{:ok, r} = PromptOnSDK.prompt("support_reply", template: "ko")    # pin "ko"
{:ok, names} = PromptOnSDK.template_names("support_reply")         # ["default", "ko"]
```

A name the deployment does not pin is `{:error, :unknown_template}` — the SDK never falls back to `"default"`
silently, because shipping English to a `"ko"` request is worse than an error.

New apps should usually keep one default template per prompt and branch inside the template with variables such as `language`; named template pins remain supported by the local decoder and conformance suite for existing snapshots.

| | v2 (deleted) | v5 |
|---|---|---|
| Config unit | `deployments[key].rules[]` with inline targets | `deployments[key]` = model + `template_pins` |
| Request-time input | `ctx` map + `target_id` + `subject_key` | `template: ` name |
| A/B split | weighted targets | — (deploy a revision, roll back if it is worse) |
| Prompt identity | `target_id`, `rule_id`, `deployment_id`, `deployment_revision` | `deployment_id`, `deployment_revision`, `template`, `prompt_version_id` |
| Logged keys | `+ rule_id`, `target_id` | `prompt_key`, `deployment_id`, `deployment_revision`, `template`, `prompt_version_id` |

Everything else is unchanged: `default_params ⊕ deployment params`, `model.provider_options ⊕ deployment
provider_options`, templates, ETag polling, disk/bundle fallback, monitoring-log envelope. v1/v2 documents (a stale disk
cache or an old repo bundle) are refused with `{:error, {:unsupported_schema_version, n}}` and the SDK keeps
polling for a v5 one.

## Logging pipeline

`log/1` never raises. Before enqueueing, the SDK applies the prompt's `payload_policy` from the prompt document
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

## Test mode

```elixir
# config/test.exs
config :prompton_sdk, mode: :test        # no HTTP; no supervisor needed

# test
import PromptOnSDK.Test

setup do
  PromptOnSDK.Test.stub("support_reply", %{
    model: "openai/gpt-4o-mini",
    messages: [
      %{role: "system", content: "You are a friendly support agent for Acme. Answer in two or three sentences; if you are not sure, say so and offer to escalate."},
      %{role: "user", content: "{{ question }}"}
    ],
    params: %{temperature: 0.3}
  })
  on_exit(&PromptOnSDK.Test.clear/0)
end

test "records a log" do
  assert :ok = perform_job(MyApp.Workers.SupportReply, %{...})        # runs in the test process
  gen = assert_logged(%{"prompt_key" => "support_reply", "status" => "ok"})
  assert gen["usage"]["input_tokens"] == 100
end
```

`PromptOnSDK.Test.put_prompt_document/1` accepts a full prompt document map, `{:file, path}` or
a decoded `PromptOnSDK.PromptDocument.t()`.
In `:test` mode `log/1` sends `{:prompton_log, gen}` (and `feedback/1` `{:prompton_feedback, map}`)
to the calling process instead of the buffer.

## Bundle export

```
mix prompton.export --out priv/prompton/prompts.production.json [--base-url URL] [--api-key KEY]
```

Fetches `GET /prompts` (flags → `PTN_BASE_URL`/`PTN_API_KEY` env → app config) and writes the JSON
plus `<out>.meta.json` (etag, last_modified, environment, exported_at). Run it in CI on every build and commit
the result; on failure the task exits non-zero and leaves the existing file untouched.

## Modules

| Layer | Modules |
|---|---|
| Pure core | `PromptDocument`, `Template`, `StopKind`, `Params` |
| Runtime | `Supervisor`, `Config`, `Buffer`, `Client`, `Client.Req`, `Payload`, `Prompt`, `Result`, `UUIDv7` |
| Adapters & tooling | `OpenRouter`, `Test`, `Mix.Tasks.Prompton.Export` |

## Conformance suite

`conformance/` holds the cross-language contract every other PromptOn SDK (Python, Node.js, Go,
Ruby, Java, Kotlin, Rust) must reproduce: template rendering, prompt selection, monitoring-log
truncation, `stop_kind` normalisation and golden log records, as JSON files with expected
values. They are generated by running this SDK (`mix run scripts/gen_conformance.exs`) and replayed
through it by `test/prompton_sdk/conformance_test.exs`. See
[conformance/README.md](conformance/README.md) for the exact semantics each file encodes.

## License

Copyright 2026 Polimo

Licensed under the Apache License, Version 2.0 (the "License"); you may not use this SDK except in
compliance with the License. You may obtain a copy of the License at
http://www.apache.org/licenses/LICENSE-2.0 — see [LICENSE](LICENSE) in this directory.

This SDK is open source under Apache-2.0. PromptOn is available as a hosted service;
the server source is private. Apps depending on `prompton_sdk` take only Apache-2.0 code.

PromptOn is a trademark of Polimo. The license does not grant permission to use the PromptOn name or
logo; forks and derived services must use a different name.
