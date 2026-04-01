defmodule Sentry.MetricsIntegrationTest do
  use Sentry.Case, async: false

  import Sentry.TestHelpers

  alias Sentry.{Metrics, TelemetryProcessor}
  alias Sentry.Telemetry.Buffer

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
    processor_name = :"test_metric_integration_#{uid}"

    start_supervised!(
      {TelemetryProcessor, name: processor_name, buffer_configs: %{metric: %{batch_size: 1}}},
      id: processor_name
    )

    Process.put(:sentry_telemetry_processor, processor_name)
    put_test_config(dsn: "http://public:secret@localhost:#{bypass.port}/1", enable_metrics: true)

    %{processor: processor_name, ref: ref, bypass: bypass}
  end

  describe "metric batching" do
    test "sends metric events as batched envelopes", ctx do
      Metrics.count("metric.1", 1)
      Metrics.gauge("metric.2", 100)

      bodies = collect_envelope_bodies(ctx.ref, 2)
      items = Enum.map(bodies, &decode_envelope!/1)
      assert length(items) == 2

      for [{header, payload}] <- items do
        assert header["type"] == "trace_metric"
        assert %{"items" => [%{"type" => _}]} = payload
      end
    end

    test "flush drains metric buffer completely", ctx do
      # Use buffered mode
      put_test_config(send_result: :none)

      scheduler = TelemetryProcessor.get_scheduler(ctx.processor)
      :sys.suspend(scheduler)

      Metrics.count("flush.1", 1)
      Metrics.count("flush.2", 2)
      Metrics.count("flush.3", 3)

      buffer = TelemetryProcessor.get_buffer(ctx.processor, :metric)
      assert Buffer.size(buffer) == 3

      :sys.resume(scheduler)
      :ok = TelemetryProcessor.flush(ctx.processor)

      assert Buffer.size(buffer) == 0

      bodies = collect_envelope_bodies(ctx.ref, 3)
      assert length(bodies) == 3
    end

    test "applies before_send_metric callback", ctx do
      put_test_config(
        before_send_metric: fn metric ->
          if metric.value < 10, do: nil, else: metric
        end
      )

      Metrics.count("keep.me", 15)
      Metrics.count("drop.me", 5)

      bodies = collect_envelope_bodies(ctx.ref, 1)
      assert length(bodies) == 1

      [items] = Enum.map(bodies, &decode_envelope!/1)

      assert [
               {%{"type" => "trace_metric"},
                %{"items" => [%{"name" => "keep.me", "value" => 15}]}}
             ] =
               items

      # The dropped metric should not produce an envelope
      ref = ctx.ref
      refute_receive {^ref, _body}, 200
    end

    test "callback can modify metrics before sending", ctx do
      put_test_config(
        before_send_metric: fn metric ->
          %{metric | value: metric.value * 2}
        end
      )

      Metrics.count("test.metric", 5)

      bodies = collect_envelope_bodies(ctx.ref, 1)
      [items] = Enum.map(bodies, &decode_envelope!/1)
      [{%{"type" => "trace_metric"}, %{"items" => [metric]}}] = items
      assert metric["value"] == 10
    end
  end

  describe "metric envelope format" do
    test "metrics include all required fields", ctx do
      Metrics.count("test.counter", 42, unit: "request", attributes: %{method: "GET"})

      bodies = collect_envelope_bodies(ctx.ref, 1)
      [items] = Enum.map(bodies, &decode_envelope!/1)
      [{header, payload}] = items

      assert header["type"] == "trace_metric"

      assert header["content_type"] == "application/vnd.sentry.items.trace-metric+json"

      %{"items" => [metric]} = payload
      assert metric["type"] == "counter"
      assert metric["name"] == "test.counter"
      assert metric["value"] == 42
      assert metric["unit"] == "request"
      assert metric["timestamp"]

      # Check default attributes
      attrs = metric["attributes"]
      assert attrs["sentry.sdk.name"]["value"] == "sentry.elixir"
      assert attrs["method"]["value"] == "GET"
    end

    test "metrics include environment and release", ctx do
      put_test_config(environment_name: "production", release: "1.0.0")

      Metrics.gauge("memory.usage", 1024)

      bodies = collect_envelope_bodies(ctx.ref, 1)
      [items] = Enum.map(bodies, &decode_envelope!/1)
      [{_header, %{"items" => [metric]}}] = items

      attrs = metric["attributes"]
      assert attrs["sentry.environment"]["value"] == "production"
      assert attrs["sentry.release"]["value"] == "1.0.0"
    end

    test "all three metric types are supported", ctx do
      Metrics.count("counter.metric", 1)
      Metrics.gauge("gauge.metric", 100)
      Metrics.distribution("distribution.metric", 3.14)

      bodies = collect_envelope_bodies(ctx.ref, 3)
      items = Enum.flat_map(bodies, &decode_envelope!/1)

      types = Enum.map(items, fn {_header, %{"items" => [metric]}} -> metric["type"] end)
      assert "counter" in types
      assert "gauge" in types
      assert "distribution" in types
    end
  end

  # Helper functions

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
end
