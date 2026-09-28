# Changelog

## 0.4.2

- Read trace-event `/logs` acknowledgements from the nested `events` response, including rejected event evidence and telemetry counts, matching the server contract.
- Make test-mode `log_events(sync: true)` return the same nested acknowledgement shape as live mode.
- Drain the trace-event lane during explicit flush and supervisor shutdown.

## 0.4.1

- Patch release aligning all SDKs on the current `/prompts` runtime API and `prompt_key` log contract. Elixir already used the canonical paths and fields; this release keeps version parity.

## 0.4.0

- Read schema v7 prompt documents with chat tool definitions and dynamic message slots.
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
