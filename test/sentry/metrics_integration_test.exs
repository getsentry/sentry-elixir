defmodule Sentry.MetricsIntegrationTest do
  use Sentry.Case, async: true

  import Sentry.TestHelpers
  import Sentry.Test.Assertions

  alias Sentry.{Metrics, TelemetryProcessor}
  alias Sentry.Telemetry.Buffer

  setup do
    %{bypass: bypass, telemetry_processor: processor_name, ref: ref} =
      Sentry.Test.setup_sentry(
        collect_envelopes: true,
        enable_metrics: true,
        telemetry_processor: [buffer_configs: %{metric: %{batch_size: 1}}]
      )

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

    test "applies before_send_metric callback" do
      put_test_config(
        before_send_metric: fn metric ->
          if metric.value < 10, do: nil, else: metric
        end
      )

      Metrics.count("keep.me", 15)
      Metrics.count("drop.me", 5)

      assert_sentry_metric(:counter, name: "keep.me", value: 15)

      # The dropped metric never reaches the collector
      assert [] == Sentry.Test.pop_sentry_metrics()
    end

    test "callback can modify metrics before sending" do
      put_test_config(
        before_send_metric: fn metric ->
          %{metric | value: metric.value * 2}
        end
      )

      Metrics.count("test.metric", 5)

      assert_sentry_metric(:counter, name: "test.metric", value: 10)
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

    test "metrics include environment and release" do
      put_test_config(environment_name: "production", release: "1.0.0")

      Metrics.gauge("memory.usage", 1024)

      assert_sentry_metric(:gauge,
        name: "memory.usage",
        attributes: %{
          "sentry.environment" => "production",
          "sentry.release" => "1.0.0"
        }
      )
    end

    test "all three metric types are supported" do
      Metrics.count("counter.metric", 1)
      Metrics.gauge("gauge.metric", 100)
      Metrics.distribution("distribution.metric", 3.14)

      assert_sentry_metric(:counter, name: "counter.metric")
      assert_sentry_metric(:gauge, name: "gauge.metric")
      assert_sentry_metric(:distribution, name: "distribution.metric")
    end
  end
end
