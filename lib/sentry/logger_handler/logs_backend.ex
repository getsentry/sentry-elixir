defmodule Sentry.LoggerHandler.LogsBackend do
  @moduledoc false

  # Backend that sends log events to Sentry's Logs Protocol.
  #
  # This backend is enabled at handler setup time when:
  # 1. `enable_logs: true` is set in Sentry configuration
  # 2. `logs_level` is configured in the handler
  #
  # Configuration options:
  # - `:logs_level` - Minimum log level to send
  # - `:logs_excluded_domains` - Domains to exclude
  # - `:logs_metadata` - Metadata keys to include as attributes
  # - `:logs_buffer` - Buffer process for batching (defaults to LogEventBuffer)

  @behaviour Sentry.LoggerHandler.Backend

  require Logger

  alias Sentry.{LogEvent, LogEventBuffer, LoggerUtils}

  @impl true
  def handle_event(%{level: log_level, meta: log_meta} = log_event, config, _handler_id) do
    cond do
      # Check if logs_level is configured
      is_nil(config.logs_level) ->
        :ok

      # Check log level
      Logger.compare_levels(log_level, config.logs_level) == :lt ->
        :ok

      # Check excluded domains for logs
      LoggerUtils.excluded_domain?(Map.get(log_meta, :domain, []), config.logs_excluded_domains) ->
        :ok

      true ->
        send_log_event(log_event, config)
    end
  end

  defp send_log_event(%{meta: log_meta} = log_event, config) do
    # Extract metadata as attributes
    attributes = extract_metadata(log_meta, config.logs_metadata)

    # Extract parameters for message template interpolation (if provided via metadata)
    parameters = Map.get(log_meta, :parameters)

    # Create log event
    log_event_struct = LogEvent.from_logger_event(log_event, attributes, parameters)

    # Add to buffer
    LogEventBuffer.add_event(log_event_struct, server: config.logs_buffer)

    :ok
  end

  defp extract_metadata(_log_meta, []), do: %{}

  defp extract_metadata(log_meta, :all) do
    log_meta
    |> Map.drop([:time, :gl, :report_cb, :domain, :mfa, :file, :line, :pid])
    |> Enum.into(%{})
  end

  defp extract_metadata(log_meta, metadata_keys) when is_list(metadata_keys) do
    Enum.reduce(metadata_keys, %{}, fn key, acc ->
      case Map.fetch(log_meta, key) do
        {:ok, value} -> Map.put(acc, key, value)
        :error -> acc
      end
    end)
  end
end
