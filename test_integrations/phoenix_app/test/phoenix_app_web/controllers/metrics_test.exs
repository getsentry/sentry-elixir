defmodule Sentry.Integrations.Phoenix.MetricsTest do
  use PhoenixAppWeb.ConnCase, async: false

  import Sentry.Test.Assertions

  setup do
    Sentry.Test.setup_sentry()
    :ok
  end

  describe "metrics from HTTP requests" do
    test "GET /metrics emits counter, gauge, and distribution metrics", %{conn: conn} do
      get(conn, ~p"/metrics")

      metrics = pop_metrics()

      types = metrics |> Enum.map(& &1.type) |> Enum.uniq()
      assert :counter in types
      assert :gauge in types
      assert :distribution in types
    end

    test "counter metric includes request attributes", %{conn: conn} do
      get(conn, ~p"/metrics")

      metrics = pop_metrics()

      counter = find_sentry_report!(metrics, name: "http.requests", type: :counter)
      assert counter.value == 1
      assert counter.attributes[:method] == "GET"
      assert counter.attributes[:path] == "/metrics"
    end

    test "metrics inside traced spans have trace context", %{conn: conn} do
      get(conn, ~p"/metrics")

      metrics = pop_metrics()

      traced_metrics = Enum.filter(metrics, &(&1.name in ["users.count", "db.query_time"]))

      assert length(traced_metrics) == 2

      for metric <- traced_metrics do
        assert is_binary(metric.trace_id), "expected trace_id on #{metric.name}"
        assert String.length(metric.trace_id) == 32
        assert is_binary(metric.span_id), "expected span_id on #{metric.name}"
        assert String.length(metric.span_id) == 16
      end
    end

    test "traced metrics from same request share trace_id", %{conn: conn} do
      get(conn, ~p"/metrics")

      metrics = pop_metrics()

      traced_metrics = Enum.filter(metrics, &(&1.span_id != nil))
      assert length(traced_metrics) >= 2

      trace_ids = traced_metrics |> Enum.map(& &1.trace_id) |> Enum.uniq()
      assert length(trace_ids) == 1
    end

    test "separate requests produce different trace_ids", %{conn: conn} do
      get(conn, ~p"/metrics")
      metrics1 = pop_metrics()

      get(conn, ~p"/metrics")
      metrics2 = pop_metrics()

      traced1 = find_sentry_report!(metrics1, name: "users.count")
      traced2 = find_sentry_report!(metrics2, name: "users.count")

      assert traced1.trace_id != traced2.trace_id
    end
  end

  defp pop_metrics do
    Sentry.TelemetryProcessor.flush()
    Sentry.Test.pop_sentry_metrics()
  end
end
