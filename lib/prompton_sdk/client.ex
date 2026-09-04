defmodule PromptOnSDK.Client do
  @moduledoc """
  PromptOn HTTP layer behaviour (§7.6). The default implementation is `PromptOnSDK.Client.Req`;
  replace it with the `client:` setting (the SDK's own tests inject the fake client from
  `test/support`, a plain module without Mox).

  Every callback takes a `PromptOnSDK.Config.t()` as its first argument (so implementations can be
  stateless). Return values:

  * `fetch_snapshot/3`: `{:ok, %{status: 200, body: binary | map, etag, last_modified}}` |
    `{:ok, %{status: 304}}` | `{:ok, %{status: other, body: term}}` | `{:error, term}`.
    `body` is the **raw bytes** (written to the disk cache as is); if a map is returned, the SDK
    re-serializes it. `opts[:receive_timeout]` is the timeout for this request only (the boot
    fetch uses 3 seconds).
  * `post_generations/2`, `post_feedback/2`:
    `{:ok, %{status: integer, body: map | binary, headers: map}}` | `{:error, term}`.
    `headers` is a map with lowercase keys (see `"retry-after"`).
  """

  alias PromptOnSDK.Config

  @type snapshot_response ::
          %{
            status: 200,
            body: binary() | map(),
            etag: String.t() | nil,
            last_modified: String.t() | nil
          }
          | %{status: 304}
          | %{status: pos_integer(), body: term()}

  @type post_response :: %{
          status: pos_integer(),
          body: term(),
          headers: %{String.t() => String.t()}
        }

  @callback fetch_snapshot(Config.t(), etag :: String.t() | nil, opts :: keyword()) ::
              {:ok, snapshot_response()} | {:error, term()}
  @callback post_generations(Config.t(), [map()]) :: {:ok, post_response()} | {:error, term()}
  @callback post_feedback(Config.t(), [map()]) :: {:ok, post_response()} | {:error, term()}
end
