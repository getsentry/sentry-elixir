defmodule Sentry.TelemetryProcessorIntegrationTest do
  use Sentry.Case, async: false

  import Sentry.TestHelpers

  alias Sentry.TelemetryProcessor
  alias Sentry.Telemetry.Buffer
  alias Sentry.LogEvent

  setup context do
    bypass = Bypass.open()
    test_pid = self()
    ref = make_ref()

    Bypass.expect(bypass, "POST", "/api/1/envelope/", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {ref, body})
      Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
    end)

    stop_supervised!(context.telemetry_processor)

    uid = System.unique_integer([:positive])
    processor_name = :"test_integration_#{uid}"

    start_supervised!(
      {TelemetryProcessor, name: processor_name, buffer_configs: %{log: %{batch_size: 1}}},
      id: processor_name
    )

    Process.put(:sentry_telemetry_processor, processor_name)
    put_test_config(dsn: "http://public:secret@localhost:#{bypass.port}/1")

    %{processor: processor_name, ref: ref, bypass: bypass}
  end

  describe "error events with telemetry_processor_categories" do
    setup do
      put_test_config(telemetry_processor_categories: [:error, :log])
      :ok
    end

    test "buffers error events through TelemetryProcessor when opted in", ctx do
      scheduler = TelemetryProcessor.get_scheduler(ctx.processor)
      :sys.suspend(scheduler)

      Sentry.capture_message("integration test error", result: :none)

      error_buffer = TelemetryProcessor.get_buffer(ctx.processor, :error)
      assert Buffer.size(error_buffer) == 1

      :sys.resume(scheduler)

      bodies = collect_envelope_bodies(ctx.ref, 1)
      assert length(bodies) == 1

      [items] = Enum.map(bodies, &decode_envelope!/1)
      assert [{%{"type" => "event"}, event}] = items
      assert event["message"]["formatted"] == "integration test error"
    end

    test "critical errors are not starved by high-volume log events", ctx do
      scheduler = TelemetryProcessor.get_scheduler(ctx.processor)
      :sys.suspend(scheduler)

      for _i <- 1..50 do
        TelemetryProcessor.add(ctx.processor, make_log_event("flood-log"))
      end

      for i <- 1..3 do
        Sentry.capture_message("critical-error-#{i}", result: :none)
      end

      error_buffer = TelemetryProcessor.get_buffer(ctx.processor, :error)
      log_buffer = TelemetryProcessor.get_buffer(ctx.processor, :log)
      assert Buffer.size(error_buffer) == 3
      assert Buffer.size(log_buffer) == 50

      :sys.resume(scheduler)

      bodies = collect_envelope_bodies(ctx.ref, 5)
      items = Enum.map(bodies, &decode_envelope!/1)
      categories = Enum.map(items, &decoded_envelope_category/1)

      error_count = Enum.count(categories, &(&1 == :error))
      assert error_count == 3

      first_three = Enum.take(categories, 3)
      assert first_three == [:error, :error, :error]
    end

    test "flush drains error buffer completely", ctx do
      scheduler = TelemetryProcessor.get_scheduler(ctx.processor)
      :sys.suspend(scheduler)

      for i <- 1..5 do
        Sentry.capture_message("flush-error-#{i}", result: :none)
      end

      error_buffer = TelemetryProcessor.get_buffer(ctx.processor, :error)
      assert Buffer.size(error_buffer) == 5

      :sys.resume(scheduler)
      :ok = TelemetryProcessor.flush(ctx.processor)

      assert Buffer.size(error_buffer) == 0

      bodies = collect_envelope_bodies(ctx.ref, 5)
      items = Enum.map(bodies, &decode_envelope!/1)
      assert length(items) == 5
      assert Enum.all?(items, fn [{%{"type" => type}, _}] -> type == "event" end)
    end
  end

  describe "log batching" do
    test "sends log events as batched envelopes", ctx do
      TelemetryProcessor.add(ctx.processor, make_log_event("log-1"))
      TelemetryProcessor.add(ctx.processor, make_log_event("log-2"))

      bodies = collect_envelope_bodies(ctx.ref, 2)
      items = Enum.map(bodies, &decode_envelope!/1)
      assert length(items) == 2

      for [{header, payload}] <- items do
        assert header["type"] == "log"
        assert %{"items" => [%{"body" => _}]} = payload
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

      bodies = collect_envelope_bodies(ctx.ref, 3)
      assert length(bodies) == 3
    end

    test "applies before_send_log callback", ctx do
      put_test_config(
        before_send_log: fn log_event ->
          if log_event.body == "drop me", do: nil, else: log_event
        end
      )

      TelemetryProcessor.add(ctx.processor, make_log_event("keep me"))
      TelemetryProcessor.add(ctx.processor, make_log_event("drop me"))

      bodies = collect_envelope_bodies(ctx.ref, 1)
      assert length(bodies) == 1

      [items] = Enum.map(bodies, &decode_envelope!/1)
      assert [{%{"type" => "log"}, %{"items" => [%{"body" => "keep me"}]}}] = items

      # The dropped event should not produce an envelope
      ref = ctx.ref
      refute_receive {^ref, _body}, 200
    end
  end

  defp make_log_event(body) do
    %LogEvent{
      timestamp: System.system_time(:nanosecond) / 1_000_000_000,
      level: :info,
      body: body
    }
  end

  defp collect_envelope_bodies(ref, expected_count) do
    collect_envelope_bodies(ref, expected_count, [])
  end

  defp collect_envelope_bodies(_ref, 0, acc), do: Enum.reverse(acc)

  defp collect_envelope_bodies(ref, remaining, acc) do
    receive do
      {^ref, body} -> collect_envelope_bodies(ref, remaining - 1, [body | acc])
    after
      2000 -> Enum.reverse(acc)
    end
  end

  defp decoded_envelope_category([{%{"type" => "event"}, _} | _]), do: :error
  defp decoded_envelope_category([{%{"type" => "log"}, _} | _]), do: :log
end
