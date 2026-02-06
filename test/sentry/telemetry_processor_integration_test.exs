defmodule Sentry.TelemetryProcessorIntegrationTest do
  use Sentry.Case, async: false

  import Sentry.TestHelpers

  alias Sentry.TelemetryProcessor
  alias Sentry.Telemetry.Buffer
  alias Sentry.{Envelope, LogBatch, LogEvent}

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

  describe "log batching" do
    test "sends log events as batched envelopes", ctx do
      TelemetryProcessor.add(ctx.processor, make_log_event("log-1"))
      TelemetryProcessor.add(ctx.processor, make_log_event("log-2"))

      envelopes = collect_envelopes(ctx.ref, 2)
      assert length(envelopes) == 2

      for envelope <- envelopes do
        assert [%LogBatch{log_events: [%LogEvent{}]}] = envelope.items
      end
    end

    test "flush drains log buffer completely", ctx do
      scheduler = TelemetryProcessor.get_scheduler(ctx.processor)
      :sys.suspend(scheduler)

      TelemetryProcessor.add(ctx.processor, make_log_event("flush-1"))
      TelemetryProcessor.add(ctx.processor, make_log_event("flush-2"))
      TelemetryProcessor.add(ctx.processor, make_log_event("flush-3"))

      buffer = TelemetryProcessor.get_buffer(ctx.processor, :log)
      assert Buffer.size(buffer) == 3

      :sys.resume(scheduler)
      :ok = TelemetryProcessor.flush(ctx.processor)

      assert Buffer.size(buffer) == 0
    end

    test "applies before_send_log callback", ctx do
      put_test_config(
        before_send_log: fn log_event ->
          if log_event.body == "drop me", do: nil, else: log_event
        end
      )

      TelemetryProcessor.add(ctx.processor, make_log_event("keep me"))
      TelemetryProcessor.add(ctx.processor, make_log_event("drop me"))

      envelopes = collect_envelopes(ctx.ref, 1)
      assert length(envelopes) == 1

      [envelope] = envelopes
      assert [%LogBatch{log_events: [%LogEvent{body: "keep me"}]}] = envelope.items

      # The dropped event should not produce an envelope
      refute_receive {_, %Envelope{}}, 200
    end
  end

  defp make_log_event(body) do
    %LogEvent{
      timestamp: System.system_time(:nanosecond) / 1_000_000_000,
      level: :info,
      body: body
    }
  end

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
end
