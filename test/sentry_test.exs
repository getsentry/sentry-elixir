defmodule SentryTest do
  use ExUnit.Case
  import ExUnit.CaptureLog
  import Sentry.TestEnvironmentHelper

  test "excludes events properly" do
    bypass = Bypass.open()

    Bypass.expect(bypass, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert body =~ "RuntimeError"
      assert conn.request_path == "/api/1/store/"
      assert conn.method == "POST"
      Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
    end)

    modify_env(
      :sentry,
      filter: Sentry.TestFilter,
      dsn: "http://public:secret@localhost:#{bypass.port}/1",
      client: Sentry.Client
    )

    assert {:ok, _} =
             Sentry.capture_exception(
               %RuntimeError{message: "error"},
               event_source: :plug,
               result: :sync
             )

    assert :excluded =
             Sentry.capture_exception(
               %ArithmeticError{message: "error"},
               event_source: :plug,
               result: :sync
             )

    assert {:ok, _} =
             Sentry.capture_message("RuntimeError: error", event_source: :plug, result: :sync)
  end

  test "errors when taking too long to receive response" do
    bypass = Bypass.open()

    Bypass.expect(bypass, fn conn ->
      :timer.sleep(100)
      assert conn.request_path == "/api/1/store/"
      assert conn.method == "POST"
      Plug.Conn.send_resp(conn, 200, ~s<{"id": "340"}>)
    end)

    modify_env(
      :sentry,
      filter: Sentry.TestFilter,
      dsn: "http://public:secret@localhost:#{bypass.port}/1"
    )

    assert capture_log(fn ->
             assert :error = Sentry.capture_message("error", [])
           end) =~ "Failed to send Sentry event"

    Bypass.pass(bypass)
  end
end
