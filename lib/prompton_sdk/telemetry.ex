defmodule PromptOnSDK.Telemetry do
  @moduledoc false

  @use_case_document_updated [:prompton, :use_case_document, :updated]
  @use_case_document_stale [:prompton, :use_case_document, :stale]
  @use_case_document_fetch_error [:prompton, :use_case_document, :fetch_error]
  @use_case_stop [:prompton, :use_case, :stop]
  @log_start [:prompton, :log, :start]
  @log_stop [:prompton, :log, :stop]
  @log_exception [:prompton, :log, :exception]
  @log_flush [:prompton, :log, :flush]
  @log_dropped [:prompton, :log, :dropped]
  @log_error [:prompton, :log, :error]

  def use_case_document_updated, do: @use_case_document_updated
  def use_case_document_stale, do: @use_case_document_stale
  def use_case_document_fetch_error, do: @use_case_document_fetch_error
  def use_case_stop, do: @use_case_stop
  def log_start, do: @log_start
  def log_stop, do: @log_stop
  def log_exception, do: @log_exception
  def log_flush, do: @log_flush
  def log_dropped, do: @log_dropped
  def log_error, do: @log_error

  @doc "All event names (for attach_many)."
  @spec events() :: [[atom()]]
  def events do
    [
      @use_case_document_updated,
      @use_case_document_stale,
      @use_case_document_fetch_error,
      @use_case_stop,
      @log_start,
      @log_stop,
      @log_exception,
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
