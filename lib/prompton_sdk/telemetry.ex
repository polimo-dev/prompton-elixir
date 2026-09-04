defmodule PromptOnSDK.Telemetry do
  @moduledoc """
  The `:telemetry` event names and payloads the SDK emits (§7.6). Attach LiveDashboard/PromEx to
  them directly. Even when the PromptOn server is down, the app sees LLM health through these
  **local metrics**.

  | Event | measurements | metadata |
  |---|---|---|
  | `[:prompton, :snapshot, :updated]` | `%{}` | `%{etag, source, environment, previous_etag}` |
  | `[:prompton, :snapshot, :stale]` | `%{age_seconds}` | `%{source, reason, etag}`; running on a disk/bundle/previous snapshot after a remote failure |
  | `[:prompton, :snapshot, :fetch_error]` | `%{}` | `%{reason, attempt, next_retry_ms}` |
  | `[:prompton, :resolve, :stop]` | `%{duration}` (native) | `%{use_case, source, prompt, deployment_id, deployment_revision, result}` |
  | `[:prompton, :generation, :start]` | `%{system_time}` | `%{id, use_case, prompt, deployment_id, model, kind, trace_id, sequence}` |
  | `[:prompton, :generation, :stop]` | `%{duration, latency_ms, input_tokens, output_tokens, cost_usd}` | `%{id, use_case, prompt, deployment_id, model, status, stop_kind, error_kind}` |
  | `[:prompton, :generation, :exception]` | `%{duration, latency_ms}` | `%{id, use_case, prompt, deployment_id, model, kind, reason, stacktrace}` |
  | `[:prompton, :log, :flush]` | `%{count, bytes, accepted, duplicates, rejected}` | `%{lane, status}` |
  | `[:prompton, :log, :dropped]` | `%{count}` | `%{reason, lane}` (`:max_buffer` / `:no_buffer` / `:encode` / `:http_4xx` / `:too_large`) |
  | `[:prompton, :log, :error]` | `%{count}` | `%{lane, reason, status, retry_in_ms}` |

  This module only provides the name constants (`snapshot_updated/0`, ...) and the `execute/3`
  wrapper.
  """

  @snapshot_updated [:prompton, :snapshot, :updated]
  @snapshot_stale [:prompton, :snapshot, :stale]
  @snapshot_fetch_error [:prompton, :snapshot, :fetch_error]
  @resolve_stop [:prompton, :resolve, :stop]
  @generation_start [:prompton, :generation, :start]
  @generation_stop [:prompton, :generation, :stop]
  @generation_exception [:prompton, :generation, :exception]
  @log_flush [:prompton, :log, :flush]
  @log_dropped [:prompton, :log, :dropped]
  @log_error [:prompton, :log, :error]

  def snapshot_updated, do: @snapshot_updated
  def snapshot_stale, do: @snapshot_stale
  def snapshot_fetch_error, do: @snapshot_fetch_error
  def resolve_stop, do: @resolve_stop
  def generation_start, do: @generation_start
  def generation_stop, do: @generation_stop
  def generation_exception, do: @generation_exception
  def log_flush, do: @log_flush
  def log_dropped, do: @log_dropped
  def log_error, do: @log_error

  @doc "All event names (for attach_many)."
  @spec events() :: [[atom()]]
  def events do
    [
      @snapshot_updated,
      @snapshot_stale,
      @snapshot_fetch_error,
      @resolve_stop,
      @generation_start,
      @generation_stop,
      @generation_exception,
      @log_flush,
      @log_dropped,
      @log_error
    ]
  end

  @doc false
  @spec execute([atom()], map(), map()) :: :ok
  def execute(event, measurements, metadata) do
    :telemetry.execute(event, measurements, metadata)
  end
end
