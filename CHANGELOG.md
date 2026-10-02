# Changelog

## Unreleased

- Suppress closed Req connection transport failures from generation logs and error completion events before
  enqueueing, preserving callback results, local telemetry, and application retry behavior.
- Retire dynamic message slot expansion. Chat prompts now render only PromptOn-managed messages;
  applications compose conversation history and the current user turn before calling the provider.
- Reject legacy `%{"type" => "slot"}` messages with
  `Message slots are not supported; compose conversation history in app code.`

## 0.5.0

- Change runtime prompt config loading to demand-driven per-prompt fetches. Startup and idle periods
  load only disk/bundle fallbacks and do not poll PromptOn.
- Fetch `GET /prompts/:key?environment=...` on prompt resolution when that key has no fresh cache,
  with a fixed 10-second freshness window, a separate fixed 10-second attempt gate, same-key
  single-flight sharing, and independent fetches for different keys.
- Bound config fetches to 1 second with no HTTP retry, ignore late responses, and fall back to the
  last valid prompt value even when expired. Cold failures return the existing SDK unresolved state.
- Add `PromptOnSDK.refresh_prompt_document(key)` for manual per-key refreshes. The no-arg refresh
  no longer performs a runtime bulk fetch; `mix prompton.export` keeps the explicit full-document
  export path.
- Add `PromptOnSDK.Client.fetch_prompt/4` for runtime demand fetches. Custom runtime clients must
  implement it; `fetch_prompts/3` remains only for explicit full-document export/bundle tooling.

## 0.4.2

- Read trace-event `/logs` acknowledgements from the nested `events` response, including rejected event evidence and telemetry counts, matching the server contract.
- Make test-mode `log_events(sync: true)` return the same nested acknowledgement shape as live mode.
- Drain the trace-event lane during explicit flush and supervisor shutdown.

## 0.4.1

- Patch release aligning all SDKs on the current `/prompts` runtime API and `prompt_key` log contract. Elixir already used the canonical paths and fields; this release keeps version parity.

## 0.4.0

- Read schema v7 prompt documents with chat tool definitions.
- Preserve native chat message fields, including tool calls and tool response linkage, during rendering.
- Prepare Chat provider requests with canonical tools while stripping PromptOn-only tool metadata.
- Add `PromptOnSDK.log_events/2` for tool-attempt/completion trace events and preserve prepared request messages/tools in generation logs.

## 0.3.1

- Use OpenRouter's System One route `/api/v1/systemone` for new Decision prepared requests.
- Continue accepting legacy pinned OpenRouter Decision deployments that use `/api/alpha/decisions`.

## 0.3.0

- Add `PromptOnSDK.request/3` for explicit deployed API/path and a rendered provider body without provider HTTP.
- Read schema v6 native Decision templates and immutable serving kinds; continue reading legacy schema v5 for existing render APIs.
- Validate native questions, provider routes and typed Decision metadata, including per-call request overrides.
- Preserve prepared-request metadata in cached/bundled documents and test stubs.
- Add `Result.from_decisions/1` and `input_decision` monitoring payloads that retain complete typed answers.

## 0.2.0

- Rename the public runtime vocabulary from resolve/render/generation to prompt/message/log.
- Add `PromptOnSDK.prompt/2` returning `{:ok, %PromptOnSDK.Prompt{}}` or a prompt selection error tuple.
- Add `PromptOnSDK.messages/3`, `PromptOnSDK.text/3`, and `PromptOnSDK.track/3` as the application-facing call flow.
- Add `PromptOnSDK.Result.from_openai/1` and `PromptOnSDK.Result.from_anthropic/1` helpers for tracked provider calls.
- Move runtime prompt document support to schema version 5, `GET /api/v1/prompts`, `POST /api/v1/logs`, `source`, `params`, and `provider_options`.
- Rename conformance fixtures to `prompt.json` and `log_record.json`.
