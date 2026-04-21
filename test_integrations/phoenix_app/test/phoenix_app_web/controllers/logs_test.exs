defmodule Sentry.Integrations.Phoenix.LogsTest do
  use PhoenixAppWeb.ConnCase, async: false

  import Sentry.Test.Assertions
  import Sentry.TestHelpers, only: [put_test_config: 1]

  setup do
    original_level = Logger.level()
    Logger.configure(level: :debug)

    on_exit(fn ->
      Logger.configure(level: original_level)
    end)

    Sentry.Test.setup_sentry()
    :ok
  end

  describe "structured logging from HTTP requests" do
    test "GET /logs captures logs with trace context", %{conn: conn} do
      get(conn, ~p"/logs")

      app_logs = pop_app_logs()
      assert length(app_logs) >= 4

      for log <- app_logs do
        assert is_binary(log.trace_id)
        assert String.length(log.trace_id) == 32
      end

      traced_logs = Enum.filter(app_logs, &(&1.span_id != nil))
      assert length(traced_logs) >= 2

      find_sentry_report!(app_logs, body: ~r/User session started/)
      find_sentry_report!(app_logs, body: ~r/Inside traced span/)
      find_sentry_report!(app_logs, body: ~r/Database query completed/)
    end

    test "GET /logs app logs share trace_id within same request", %{conn: conn} do
      get(conn, ~p"/logs")

      app_logs = pop_app_logs()

      assert length(app_logs) >= 2

      traced_logs = Enum.filter(app_logs, &(&1.span_id != nil))
      trace_ids = traced_logs |> Enum.map(& &1.trace_id) |> Enum.uniq()
      assert length(trace_ids) == 1
    end

    test "GET /logs captures logs at different levels", %{conn: conn} do
      get(conn, ~p"/logs")

      assert_sentry_log(:info, ~r/User session started/)
      assert_sentry_log(:warn, ~r/Sample warning log/)
      assert_sentry_log(:error, ~r/Sample error log/)
    end

    test "GET /logs logs have proper span hierarchy", %{conn: conn} do
      get(conn, ~p"/logs")

      app_logs = pop_app_logs()
      traced_logs = Enum.filter(app_logs, &(&1.span_id != nil))

      span_ids = traced_logs |> Enum.map(& &1.span_id) |> Enum.uniq()
      assert length(span_ids) >= 2
    end

    test "separate requests have different trace_ids", %{conn: conn} do
      get(conn, ~p"/logs")
      app_logs1 = pop_app_logs()

      get(conn, ~p"/logs")
      app_logs2 = pop_app_logs()

      assert length(app_logs1) >= 1
      assert length(app_logs2) >= 1

      trace_id_1 = hd(app_logs1).trace_id
      trace_id_2 = hd(app_logs2).trace_id

      assert trace_id_1 != trace_id_2
    end
  end

  describe "structured logging with complex metadata" do
    test "GET /logs-with-structs captures struct attributes", %{conn: conn} do
      put_test_config(logs: [level: :info, excluded_domains: [:cowboy, :ranch], metadata: :all])

      get(conn, ~p"/logs-with-structs")

      log = assert_sentry_log(:info, "Log with struct metadata")

      assert %URI{} = log.attributes[:uri]
      assert log.attributes[:uri] == URI.parse("https://example.com/path")
      assert %{method: _, path: _} = log.attributes[:conn_info]
      assert log.attributes[:tags] == [:web, :test]
    end
  end

  defp pop_app_logs do
    Sentry.TelemetryProcessor.flush()

    Sentry.Test.pop_sentry_logs()
    |> Enum.filter(fn log ->
      body = log.body

      String.contains?(body, "User session started") or
        String.contains?(body, "Processing user request") or
        String.contains?(body, "Inside traced span") or
        String.contains?(body, "Database query completed") or
        String.contains?(body, "Sample warning log") or
        String.contains?(body, "Sample error log")
    end)
  end
end
