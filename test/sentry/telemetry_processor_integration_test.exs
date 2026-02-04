defmodule Sentry.TelemetryProcessorIntegrationTest do
  use Sentry.Case, async: false

  import Sentry.TestHelpers

  alias Sentry.TelemetryProcessor
  alias Sentry.Telemetry.Buffer
  alias Sentry.{Envelope, Event, CheckIn, LogBatch, LogEvent, Transaction}

  setup context do
    test_pid = self()
    ref = make_ref()

    stop_supervised!(context.telemetry_processor)

    uid = System.unique_integer([:positive])
    processor_name = :"test_integration_#{uid}"

    start_supervised!(
      {TelemetryProcessor,
       name: processor_name,
       on_envelope: fn envelope -> send(test_pid, {ref, envelope}) end,
       buffer_configs: %{log: %{batch_size: 1}}},
      id: processor_name
    )

    Process.put(:sentry_telemetry_processor, processor_name)
    put_test_config(dsn: "http://public:secret@localhost:9999/1")

    %{processor: processor_name, ref: ref}
  end

  describe "priority ordering" do
    test "processes all event categories in priority order: errors > check-ins > transactions > logs",
         ctx do
      scheduler = TelemetryProcessor.get_scheduler(ctx.processor)

      :sys.suspend(scheduler)

      Sentry.capture_message("integration test error", result: :none)

      Sentry.capture_check_in(
        status: :ok,
        monitor_slug: "integration-test-monitor",
        result: :none
      )

      Sentry.send_transaction(create_transaction(), result: :none)
      TelemetryProcessor.add(ctx.processor, make_log_event())

      assert_buffer_sizes(ctx.processor, %{error: 1, check_in: 1, transaction: 1, log: 1})

      :sys.resume(scheduler)

      envelopes = collect_envelopes(ctx.ref, 4)
      categories = Enum.map(envelopes, &envelope_category/1)

      assert categories == [:error, :check_in, :transaction, :log]
    end

    test "weighted round-robin distributes slots proportionally under load", ctx do
      scheduler = TelemetryProcessor.get_scheduler(ctx.processor)
      :sys.suspend(scheduler)

      for i <- 1..10 do
        Sentry.capture_message("error-#{i}", result: :none)
        Sentry.capture_check_in(status: :ok, monitor_slug: "monitor-#{i}", result: :none)
        Sentry.send_transaction(create_transaction(%{span_id: "span-#{i}"}), result: :none)
        TelemetryProcessor.add(ctx.processor, make_log_event())
      end

      assert_buffer_sizes(ctx.processor, %{error: 10, check_in: 10, transaction: 10, log: 10})

      :sys.resume(scheduler)

      envelopes = collect_envelopes(ctx.ref, 14)
      categories = Enum.map(envelopes, &envelope_category/1)

      counts = Enum.frequencies(categories)
      assert counts[:error] == 5
      assert counts[:check_in] == 4
      assert counts[:transaction] == 3
      assert counts[:log] == 2

      assert categories ==
               List.duplicate(:error, 5) ++
                 List.duplicate(:check_in, 4) ++
                 List.duplicate(:transaction, 3) ++
                 List.duplicate(:log, 2)
    end

    test "critical errors are not starved by high-volume lower-priority events", ctx do
      scheduler = TelemetryProcessor.get_scheduler(ctx.processor)
      :sys.suspend(scheduler)

      for i <- 1..50 do
        TelemetryProcessor.add(ctx.processor, make_log_event())
        Sentry.send_transaction(create_transaction(%{span_id: "flood-#{i}"}), result: :none)
      end

      for i <- 1..3 do
        Sentry.capture_message("critical-error-#{i}", result: :none)
      end

      assert_buffer_sizes(ctx.processor, %{error: 3, transaction: 50, log: 50})

      :sys.resume(scheduler)

      envelopes = collect_envelopes(ctx.ref, 14)
      categories = Enum.map(envelopes, &envelope_category/1)

      error_count = Enum.count(categories, &(&1 == :error))
      assert error_count == 3

      first_three = Enum.take(categories, 3)
      assert first_three == [:error, :error, :error]
    end
  end

  defp make_log_event do
    %LogEvent{
      timestamp: System.system_time(:nanosecond) / 1_000_000_000,
      level: :info,
      body: "integration test log"
    }
  end

  defp envelope_category(%Envelope{items: [%Event{} | _]}), do: :error
  defp envelope_category(%Envelope{items: [%CheckIn{} | _]}), do: :check_in
  defp envelope_category(%Envelope{items: [%Transaction{} | _]}), do: :transaction
  defp envelope_category(%Envelope{items: [%LogBatch{} | _]}), do: :log

  defp collect_envelopes(ref, expected_count) do
    collect_envelopes(ref, expected_count, [])
  end

  defp collect_envelopes(_ref, 0, acc), do: Enum.reverse(acc)

  defp collect_envelopes(ref, remaining, acc) do
    receive do
      {^ref, envelope} -> collect_envelopes(ref, remaining - 1, [envelope | acc])
    after
      1000 -> Enum.reverse(acc)
    end
  end

  defp assert_buffer_sizes(processor, expected) do
    for {category, expected_size} <- expected do
      buffer = TelemetryProcessor.get_buffer(processor, category)

      assert Buffer.size(buffer) == expected_size,
             "expected #{category} buffer to have #{expected_size} items"
    end
  end
end
