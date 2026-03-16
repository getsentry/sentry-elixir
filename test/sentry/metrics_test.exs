defmodule Sentry.MetricsTest do
  use Sentry.Case, async: true

  import Sentry.TestHelpers

  alias Sentry.{Metric, Metrics}

  setup do
    put_test_config(dsn: nil)
    :ok
  end

  describe "count/2" do
    test "creates a counter metric with default options" do
      put_test_config(enable_metrics: true)

      assert :ok = Metrics.count("button.clicks", 1)
    end

    test "creates a counter metric with unit" do
      put_test_config(enable_metrics: true)

      assert :ok = Metrics.count("http.requests", 5, unit: "request")
    end

    test "creates a counter metric with attributes" do
      put_test_config(enable_metrics: true)

      assert :ok =
               Metrics.count("button.clicks", 1,
                 unit: "click",
                 attributes: %{button_id: "submit"}
               )
    end

    test "respects enable_metrics kill switch when false" do
      test_pid = self()

      callback = fn metric ->
        send(test_pid, {:metric_sent, metric})
        metric
      end

      put_test_config(enable_metrics: false, before_send_metric: callback)

      # Should not raise error, just silently return :ok
      assert :ok = Metrics.count("button.clicks", 1)

      # Verify the metric was NOT sent and callback was NOT called
      refute_receive {:metric_sent, _}, 100
    end

    test "applies before_send_metric callback" do
      test_pid = self()

      callback = fn metric ->
        send(test_pid, {:callback_called, metric})
        metric
      end

      put_test_config(enable_metrics: true, before_send_metric: callback)

      Metrics.count("test.counter", 42, unit: "item")

      assert_receive {:callback_called, %Metric{} = metric}
      assert metric.type == :counter
      assert metric.name == "test.counter"
      assert metric.value == 42
      assert metric.unit == "item"
    end

    test "default attributes are available to before_send_metric callback" do
      test_pid = self()

      callback = fn metric ->
        send(test_pid, {:callback_with_attrs, metric.attributes})
        metric
      end

      put_test_config(
        enable_metrics: true,
        before_send_metric: callback,
        environment_name: "test",
        release: "1.0.0"
      )

      Metrics.count("test.counter", 1)

      assert_receive {:callback_with_attrs, attrs}
      # Verify default attributes are present before callback
      assert attrs["sentry.sdk.name"] == "sentry.elixir"
      assert attrs["sentry.environment"] == "test"
      assert attrs["sentry.release"] == "1.0.0"
      assert is_binary(attrs["sentry.sdk.version"])
    end

    test "filters metric when before_send_metric returns nil" do
      callback = fn _metric -> nil end
      put_test_config(enable_metrics: true, before_send_metric: callback)

      # Should not crash, just skip sending
      assert :ok = Metrics.count("test.counter", 1)
    end

    test "filters metric when before_send_metric returns false" do
      callback = fn _metric -> false end
      put_test_config(enable_metrics: true, before_send_metric: callback)

      # Should not crash, just skip sending
      assert :ok = Metrics.count("test.counter", 1)
    end

    test "allows before_send_metric to modify metric" do
      test_pid = self()

      callback = fn metric ->
        send(test_pid, {:original_value, metric.value})
        %{metric | value: metric.value * 2}
      end

      put_test_config(enable_metrics: true, before_send_metric: callback)

      Metrics.count("test.counter", 5)

      assert_receive {:original_value, 5}
    end

    test "handles before_send_metric callback as {module, function} tuple" do
      defmodule TestCallback do
        def filter_metric(metric) do
          if metric.value > 10, do: metric, else: nil
        end
      end

      put_test_config(enable_metrics: true, before_send_metric: {TestCallback, :filter_metric})

      # Should be filtered out
      assert :ok = Metrics.count("test.counter", 5)

      # Should pass through
      assert :ok = Metrics.count("test.counter", 15)
    end

    test "always includes trace_id even without active span" do
      test_pid = self()

      callback = fn metric ->
        send(test_pid, {:trace_id, metric.trace_id})
        metric
      end

      put_test_config(enable_metrics: true, before_send_metric: callback)

      Metrics.count("test.counter", 1)

      assert_receive {:trace_id, trace_id}
      # trace_id is REQUIRED per spec, should never be nil
      assert is_binary(trace_id)
      assert String.length(trace_id) == 32
    end
  end

  describe "gauge/2" do
    test "creates a gauge metric with default options" do
      put_test_config(enable_metrics: true)

      assert :ok = Metrics.gauge("memory.usage", 1024)
    end

    test "creates a gauge metric with unit and attributes" do
      put_test_config(enable_metrics: true)

      assert :ok =
               Metrics.gauge("active.connections", 42,
                 unit: "connection",
                 attributes: %{pool: "main"}
               )
    end

    test "respects enable_metrics kill switch" do
      put_test_config(enable_metrics: false)

      assert :ok = Metrics.gauge("memory.usage", 1024)
    end
  end

  describe "distribution/2" do
    test "creates a distribution metric with default options" do
      put_test_config(enable_metrics: true)

      assert :ok = Metrics.distribution("response.time", 42.5)
    end

    test "creates a distribution metric with unit and attributes" do
      put_test_config(enable_metrics: true)

      assert :ok =
               Metrics.distribution("response.time", 42.5,
                 unit: "millisecond",
                 attributes: %{endpoint: "/api"}
               )
    end

    test "respects enable_metrics kill switch" do
      put_test_config(enable_metrics: false)

      assert :ok = Metrics.distribution("response.time", 42.5)
    end
  end

  describe "trace context extraction" do
    test "metrics always have trace_id (REQUIRED per spec)" do
      test_pid = self()

      callback = fn metric ->
        send(test_pid, {:metric, metric})
        metric
      end

      put_test_config(enable_metrics: true, before_send_metric: callback)

      Metrics.count("test.counter", 1)

      assert_receive {:metric, %Metric{} = metric}
      # trace_id is REQUIRED per spec - should always be present, even without active span
      assert is_binary(metric.trace_id)
      assert String.length(metric.trace_id) == 32
      # span_id is optional - nil when no active span
      assert metric.span_id == nil
    end
  end

  describe "before_send_metric error handling" do
    test "returns original metric when callback raises" do
      callback = fn _metric ->
        raise "callback error"
      end

      put_test_config(enable_metrics: true, before_send_metric: callback)

      import ExUnit.CaptureLog

      log =
        capture_log(fn ->
          assert :ok = Metrics.count("test.counter", 42)
        end)

      assert log =~ "before_send_metric callback failed"
      assert log =~ "callback error"
    end

    test "drops metric when callback returns invalid type" do
      test_pid = self()

      callback = fn _metric ->
        send(test_pid, :callback_called)
        :invalid_return
      end

      put_test_config(enable_metrics: true, before_send_metric: callback)

      assert :ok = Metrics.count("test.counter", 1)
      assert_receive :callback_called
    end
  end

  describe "edge case values" do
    test "accepts zero value" do
      test_pid = self()

      callback = fn metric ->
        send(test_pid, {:metric, metric})
        metric
      end

      put_test_config(enable_metrics: true, before_send_metric: callback)

      assert :ok = Metrics.count("test.zero", 0)
      assert_receive {:metric, %Metric{value: 0}}
    end

    test "accepts negative values" do
      test_pid = self()

      callback = fn metric ->
        send(test_pid, {:metric, metric})
        metric
      end

      put_test_config(enable_metrics: true, before_send_metric: callback)

      assert :ok = Metrics.gauge("test.negative", -42)
      assert_receive {:metric, %Metric{value: -42}}
    end

    test "accepts float values" do
      test_pid = self()

      callback = fn metric ->
        send(test_pid, {:metric, metric})
        metric
      end

      put_test_config(enable_metrics: true, before_send_metric: callback)

      assert :ok = Metrics.distribution("test.float", 0.001)
      assert_receive {:metric, %Metric{value: 0.001}}
    end
  end
end
