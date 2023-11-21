defmodule SentryTest do
  use ExUnit.Case

  import ExUnit.CaptureLog
  import Sentry.TestHelpers

  defmodule TestFilter do
    @behaviour Sentry.EventFilter

    def exclude_exception?(%ArithmeticError{}, :plug), do: true
    def exclude_exception?(_, _), do: false
  end

  test "excludes events properly" do
    bypass = Bypass.open()

    Bypass.expect(bypass, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert body =~ "RuntimeError"
      assert conn.request_path == "/api/1/envelope/"
      assert conn.method == "POST"
      Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
    end)

    modify_app_env(
      filter: TestFilter,
      dsn: "http://public:secret@localhost:#{bypass.port}/1"
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
      assert conn.request_path == "/api/1/envelope/"
      assert conn.method == "POST"
      Plug.Conn.send_resp(conn, 200, ~s<{"id": "340"}>)
    end)

    modify_app_env(
      filter: TestFilter,
      dsn: "http://public:secret@localhost:#{bypass.port}/1"
    )

    capture_log(fn ->
      assert {:error, _} = Sentry.capture_message("error", request_retries: [])
    end)

    Bypass.pass(bypass)
  end

  test "sets last_event_id_and_source when an event is sent" do
    bypass = Bypass.open()

    Bypass.expect(bypass, fn conn ->
      Plug.Conn.send_resp(conn, 200, ~s<{"id": "340"}>)
    end)

    modify_app_env(dsn: "http://public:secret@localhost:#{bypass.port}/1")

    Sentry.capture_message("test")

    assert {event_id, nil} = Sentry.get_last_event_id_and_source()
    assert is_binary(event_id)
  end

  test "ignores events without message and exception" do
    log =
      capture_log(fn ->
        assert Sentry.send_event(Sentry.Event.create_event([])) == :ignored
      end)

    assert log =~ "Sentry: unable to parse exception"
  end
end
