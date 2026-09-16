defmodule PromptOnSDK.Telemetry do
  @moduledoc false

  @prompt_document_updated [:prompton, :prompt_document, :updated]
  @prompt_document_stale [:prompton, :prompt_document, :stale]
  @prompt_document_fetch_error [:prompton, :prompt_document, :fetch_error]
  @prompt_stop [:prompton, :prompt, :stop]
  @log_start [:prompton, :log, :start]
  @log_stop [:prompton, :log, :stop]
  @log_exception [:prompton, :log, :exception]
  @log_flush [:prompton, :log, :flush]
  @log_dropped [:prompton, :log, :dropped]
  @log_error [:prompton, :log, :error]

  def prompt_document_updated, do: @prompt_document_updated
  def prompt_document_stale, do: @prompt_document_stale
  def prompt_document_fetch_error, do: @prompt_document_fetch_error
  def prompt_stop, do: @prompt_stop
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
      @prompt_document_updated,
      @prompt_document_stale,
      @prompt_document_fetch_error,
      @prompt_stop,
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
