# Changelog

## 0.2.0

- Rename the public runtime vocabulary from resolve/render/generation to use case/message/log.
- Add `PromptOnSDK.use_case/2` returning `{:ok, %PromptOnSDK.UseCase{}}` or a use-case selection error tuple.
- Add `PromptOnSDK.messages/3`, `PromptOnSDK.text/3`, and `PromptOnSDK.track/3` as the application-facing call flow.
- Add `PromptOnSDK.Result.from_openai/1` and `PromptOnSDK.Result.from_anthropic/1` helpers for tracked provider calls.
- Move runtime use-case document support to schema version 4, `GET /api/v1/use-cases`, `POST /api/v1/logs`, `source`, `params`, and `provider_options`.
- Rename conformance fixtures to `use_case.json` and `log_record.json`.
