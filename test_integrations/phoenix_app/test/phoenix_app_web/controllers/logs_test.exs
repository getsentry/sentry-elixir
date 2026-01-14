defmodule Sentry.Integrations.Phoenix.LogsTest do
  use PhoenixAppWeb.ConnCase, async: false

  import Sentry.TestHelpers

  setup do
    original_level = Logger.level()
    Logger.configure(level: :debug)

    on_exit(fn ->
      Logger.configure(level: original_level)
    end)

    put_test_config(dsn: "http://public:secret@localhost:8080/1", enable_logs: true)

    Sentry.Test.start_collecting_sentry_reports()

    _ = Sentry.Test.pop_sentry_logs()

    :ok
  end

  describe "structured logging from HTTP requests" do
    test "GET /logs captures logs with trace context", %{conn: conn} do
      conn = get(conn, ~p"/logs")

      assert json_response(conn, 200)["message"] == "Logs demo completed - check your Sentry logs!"

      logs = Sentry.Test.pop_sentry_logs()

      app_logs = filter_app_logs(logs)
      assert length(app_logs) >= 4

      for log <- app_logs do
        assert is_binary(log.trace_id)
        assert String.length(log.trace_id) == 32
      end

      traced_logs = Enum.filter(app_logs, &(&1.span_id != nil))
      assert length(traced_logs) >= 2

      log_bodies = Enum.map(app_logs, & &1.body)
      assert Enum.any?(log_bodies, &String.contains?(&1, "User session started"))
      assert Enum.any?(log_bodies, &String.contains?(&1, "Inside traced span"))
      assert Enum.any?(log_bodies, &String.contains?(&1, "Database query completed"))
    end

    test "GET /logs app logs share trace_id within same request", %{conn: conn} do
      get(conn, ~p"/logs")

      logs = Sentry.Test.pop_sentry_logs()
      app_logs = filter_app_logs(logs)

      assert length(app_logs) >= 2

      traced_logs = Enum.filter(app_logs, &(&1.span_id != nil))
      trace_ids = traced_logs |> Enum.map(& &1.trace_id) |> Enum.uniq()
      assert length(trace_ids) == 1
    end

    test "GET /logs captures logs at different levels", %{conn: conn} do
      get(conn, ~p"/logs")

      logs = Sentry.Test.pop_sentry_logs()
      app_logs = filter_app_logs(logs)

      levels = Enum.map(app_logs, & &1.level) |> Enum.uniq()

      assert :info in levels
      assert :warn in levels
      assert :error in levels
    end

    test "GET /logs logs have proper span hierarchy", %{conn: conn} do
      get(conn, ~p"/logs")

      logs = Sentry.Test.pop_sentry_logs()
      app_logs = filter_app_logs(logs)

      traced_logs = Enum.filter(app_logs, &(&1.span_id != nil))

      span_ids = traced_logs |> Enum.map(& &1.span_id) |> Enum.uniq()

      assert length(span_ids) >= 2
    end

    test "separate requests have different trace_ids", %{conn: conn} do
      get(conn, ~p"/logs")
      logs1 = Sentry.Test.pop_sentry_logs()
      app_logs1 = filter_app_logs(logs1)

      get(conn, ~p"/logs")
      logs2 = Sentry.Test.pop_sentry_logs()
      app_logs2 = filter_app_logs(logs2)

      assert length(app_logs1) >= 1
      assert length(app_logs2) >= 1

      trace_id_1 = hd(app_logs1).trace_id
      trace_id_2 = hd(app_logs2).trace_id

      assert trace_id_1 != trace_id_2
    end
  end

  defp filter_app_logs(logs) do
    Enum.filter(logs, fn log ->
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
