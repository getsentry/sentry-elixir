defmodule Sentry.Case do
  # We use this module mostly to add some additional checks before and after tests, especially
  # related to configuration. Configuration is isolated per-process via the process dictionary,
  # so tests using put_test_config/1 will have their own view without affecting other tests.

  use ExUnit.CaseTemplate

  setup context do
    # Start a fresh RateLimiter for each test with unique names for isolation.
    setup_rate_limiter()

    # Start a fresh TelemetryProcessor for each test with unique name for isolation.
    # Returns the processor name so tests can pass it to handlers for isolation.
    telemetry_processor = setup_telemetry_processor()

    # Create fresh counters with unique keys for each test to ensure complete isolation.
    # SenderPool checks process dictionary for custom keys, falling back to global defaults.
    setup_sender_pool_counters()

    span_storage_result =
      case context[:span_storage] do
        nil -> %{}
        true -> setup_span_storage([])
        opts when is_list(opts) -> setup_span_storage(opts)
      end

    Map.merge(%{telemetry_processor: telemetry_processor}, span_storage_result)
  end

  defp setup_rate_limiter do
    uid = System.unique_integer([:positive])
    rate_limiter_table = :"test_rate_limiter_#{uid}"

    Process.put(:rate_limiter_table_name, rate_limiter_table)
    start_supervised!({Sentry.Transport.RateLimiter, name: rate_limiter_table}, id: rate_limiter_table)
  end

  defp setup_telemetry_processor do
    uid = System.unique_integer([:positive])
    processor_name = :"test_telemetry_processor_#{uid}"

    start_supervised!(
      {Sentry.TelemetryProcessor, name: processor_name},
      id: processor_name
    )

    Process.put(:sentry_telemetry_processor, processor_name)
    processor_name
  end

  defp setup_sender_pool_counters do
    uid = System.unique_integer([:positive])
    events_key = {Sentry.Transport.SenderPool, {:queued_events, uid}}
    transactions_key = {Sentry.Transport.SenderPool, {:queued_transactions, uid}}

    # Create fresh counters with unique keys
    :persistent_term.put(events_key, :counters.new(1, []))
    :persistent_term.put(transactions_key, :counters.new(1, []))

    # Store keys in process dictionary so SenderPool uses them
    Process.put(:sentry_queued_events_key, events_key)
    Process.put(:sentry_queued_transactions_key, transactions_key)
  end

  defp setup_span_storage(opts) do
    uid = System.unique_integer([:positive])
    server_name = :"test_span_storage_#{uid}"
    table_name = :"test_span_storage_table_#{uid}"

    opts = [name: server_name, table_name: table_name] ++ opts
    start_supervised!({Sentry.OpenTelemetry.SpanStorage, opts})

    %{server_name: server_name, table_name: table_name}
  end
end
