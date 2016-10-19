defmodule Sentry.LoggerTest do
  use ExUnit.Case
  import ExUnit.CaptureLog

  test "exception makes call to Sentry API" do

    bypass = Bypass.open
    Bypass.expect bypass, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert body =~ "RuntimeError"
      assert body =~ "Unique Error"
      assert conn.request_path == "/api/1/store/"
      assert conn.method == "POST"
      Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
    end

    Application.put_env(:sentry, :dsn, "http://public:secret@localhost:#{bypass.port}/1")
    :error_logger.add_report_handler(Sentry.Logger)

    capture_log fn ->
      Task.start( fn ->
        raise "Unique Error"
      end)
    end

    :timer.sleep 250

    :error_logger.delete_report_handler(Sentry.Logger)
  end
end
