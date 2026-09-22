# Changelog

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
