# Changelog

## 0.2.0

- Rename the public runtime vocabulary from resolve/render/generation to prompt/message/log.
- Add `PromptOnSDK.prompt/2` returning `{:ok, %PromptOnSDK.Prompt{}}` or a prompt selection error tuple.
- Add `PromptOnSDK.messages/3`, `PromptOnSDK.text/3`, and `PromptOnSDK.track/3` as the application-facing call flow.
- Add `PromptOnSDK.Result.from_openai/1` and `PromptOnSDK.Result.from_anthropic/1` helpers for tracked provider calls.
- Move runtime prompt document support to schema version 5, `GET /api/v1/prompts`, `POST /api/v1/logs`, `source`, `params`, and `provider_options`.
- Rename conformance fixtures to `prompt.json` and `log_record.json`.
