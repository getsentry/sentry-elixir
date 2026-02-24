defmodule Sentry.LoggerHandler.LogsBackend do
  @moduledoc false

  # Backend that sends log events to Sentry's Logs Protocol.
  #
  # This backend is enabled at handler setup time when `enable_logs: true` is set
  # in Sentry configuration. Logs configuration (level, excluded_domains, metadata)
  # is read from `Sentry.Config` at runtime.

  @behaviour Sentry.LoggerHandler.Backend

  require Logger

  alias Sentry.{Config, LogEvent, LoggerUtils, TelemetryProcessor}

  @impl true
  def handle_event(%{level: log_level, meta: log_meta} = log_event, config, _handler_id) do
    cond do
      Logger.compare_levels(log_level, Config.logs_level()) == :lt ->
        :ok

      LoggerUtils.excluded_domain?(Map.get(log_meta, :domain, []), Config.logs_excluded_domains()) ->
        :ok

      true ->
        send_log_event(log_event, config)
    end
  end

  defp send_log_event(%{meta: log_meta} = log_event, config) do
    attributes = extract_metadata(log_meta, Config.logs_metadata())

    # Extract parameters for message template interpolation (if provided via metadata)
    parameters = Map.get(log_meta, :parameters)

    # Create log event
    log_event_struct = LogEvent.from_logger_event(log_event, attributes, parameters)

    # Add to TelemetryProcessor buffer (use configured processor for test isolation)
    case TelemetryProcessor.add(config.telemetry_processor, log_event_struct) do
      {:ok, {:rate_limited, data_category}} ->
        Sentry.ClientReport.Sender.record_discarded_events(:ratelimit_backoff, data_category)

      :ok ->
        :ok
    end

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
