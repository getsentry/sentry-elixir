defmodule Sentry.MetricsIntegrationTest do
  use Sentry.Case, async: false

  import Sentry.TestHelpers
  import Sentry.Test.Assertions

  alias Sentry.{Metrics, TelemetryProcessor}
  alias Sentry.Telemetry.Buffer

  setup context do
    bypass = Bypass.open()

    ref = setup_bypass_envelope_collector(bypass)

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

      batches = collect_sentry_metric_items(ctx.ref, 2)
      assert length(batches) == 2

      for batch <- batches do
        assert %{"items" => [%{"type" => _}]} = batch
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

      batches = collect_sentry_metric_items(ctx.ref, 3)
      assert length(batches) == 3
    end

    test "applies before_send_metric callback", ctx do
      put_test_config(
        before_send_metric: fn metric ->
          if metric.value < 10, do: nil, else: metric
        end
      )

      Metrics.count("keep.me", 15)
      Metrics.count("drop.me", 5)

      [%{"items" => [metric]}] = collect_sentry_metric_items(ctx.ref, 1)
      assert_sentry_report(metric, name: "keep.me", value: 15)

      # The dropped metric should not produce an envelope
      ref = ctx.ref
      refute_receive {:bypass_envelope, ^ref, _body}, 200
    end

    test "callback can modify metrics before sending", ctx do
      put_test_config(
        before_send_metric: fn metric ->
          %{metric | value: metric.value * 2}
        end
      )

      Metrics.count("test.metric", 5)

      [%{"items" => [metric]}] = collect_sentry_metric_items(ctx.ref, 1)
      assert_sentry_report(metric, value: 10)
    end
  end

  describe "metric envelope format" do
    test "metrics include all required fields", ctx do
      Metrics.count("test.counter", 42, unit: "request", attributes: %{method: "GET"})

      [[{header, %{"items" => [metric]} = payload}]] = collect_envelopes(ctx.ref, 1)
      assert header["content_type"] == "application/vnd.sentry.items.trace-metric+json"

      assert_sentry_report(metric,
        type: "counter",
        name: "test.counter",
        value: 42,
        unit: "request",
        attributes: %{
          :"sentry.sdk.name" => %{value: "sentry.elixir"},
          method: %{value: "GET"}
        }
      )

      assert payload["items"] |> hd() |> Map.get("timestamp")
    end

    test "metrics include environment and release", ctx do
      put_test_config(environment_name: "production", release: "1.0.0")

      Metrics.gauge("memory.usage", 1024)

      [%{"items" => [metric]}] = collect_sentry_metric_items(ctx.ref, 1)

      assert_sentry_report(metric,
        attributes: %{
          :"sentry.environment" => %{value: "production"},
          :"sentry.release" => %{value: "1.0.0"}
        }
      )
    end

    test "all three metric types are supported", ctx do
      Metrics.count("counter.metric", 1)
      Metrics.gauge("gauge.metric", 100)
      Metrics.distribution("distribution.metric", 3.14)

      batches = collect_sentry_metric_items(ctx.ref, 3)
      metrics = Enum.flat_map(batches, fn %{"items" => items} -> items end)

      find_sentry_report!(metrics, type: "counter")
      find_sentry_report!(metrics, type: "gauge")
      find_sentry_report!(metrics, type: "distribution")
    end
  end
end
