defmodule SentryTest do
  use Sentry.Case
  use Plug.Test

  import ExUnit.CaptureLog
  import Sentry.TestHelpers

  defmodule TestFilter do
    @behaviour Sentry.EventFilter

    def exclude_exception?(%ArithmeticError{}, :plug), do: true
    def exclude_exception?(_, _), do: false
  end

  setup do
    bypass = Bypass.open()
    put_test_config(dsn: "http://public:secret@localhost:#{bypass.port}/1", dedup_events: false)
    %{bypass: bypass}
  end

  test "excludes events properly", %{bypass: bypass} do
    Bypass.expect(bypass, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert body =~ "RuntimeError"
      assert conn.request_path == "/api/1/envelope/"
      assert conn.method == "POST"
      Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
    end)

    put_test_config(filter: TestFilter)

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

  @tag :capture_log
  test "errors when taking too long to receive response", %{bypass: bypass} do
    Bypass.expect(bypass, fn _conn -> Process.sleep(:infinity) end)

    put_test_config(hackney_opts: [recv_timeout: 50])

    assert {:error, {:request_failure, :timeout}} =
             Sentry.capture_message("error", request_retries: [], result: :sync)

    Bypass.pass(bypass)
  end

  test "sets last_event_id_and_source when an event is sent", %{bypass: bypass} do
    Bypass.expect(bypass, fn conn ->
      Plug.Conn.send_resp(conn, 200, ~s<{"id": "340"}>)
    end)

    Sentry.capture_message("test")

    assert {event_id, nil} = Sentry.get_last_event_id_and_source()
    assert is_binary(event_id)
  end

  test "ignores events without message and exception" do
    log =
      capture_log(fn ->
        assert Sentry.send_event(Sentry.Event.create_event([])) == :ignored
      end)

    assert log =~ "Cannot report event without message or exception: %Sentry.Event{"
  end

  test "doesn't incur into infinite logging loops because we prevent that", %{bypass: bypass} do
    put_test_config(dedup_events: true)
    message_to_report = "Hello #{System.unique_integer([:positive])}"

    Bypass.expect(bypass, fn conn ->
      Plug.Conn.send_resp(conn, 200, ~s<{"id": "340"}>)
    end)

    :ok =
      :logger.add_handler(:sentry_handler, Sentry.LoggerHandler, %{
        config: %{capture_log_messages: true, level: :debug}
      })

    on_exit(fn ->
      _ = :logger.remove_handler(:sentry_handler)
    end)

    # First one is reported correctly as it has no duplicates
    assert {:ok, "340"} = Sentry.capture_message(message_to_report)

    log =
      capture_log(fn ->
        # Then, we log the same message, which triggers the SDK to log that the message wasn't sent
        # because it's a duplicate.
        assert :excluded = Sentry.capture_message(message_to_report)

        # Then we log the same message again, which again triggers the SDK to log that the message
        # wasn't sent. But this time, *that* log (the one about the duplicate event) is also a
        # duplicate. So, we can test that it doesn't result in an infinite logging loop.
        assert :excluded = Sentry.capture_message(message_to_report)
      end)

    logged_count =
      ~r/Event dropped due to being a duplicate/
      |> Regex.scan(log)
      |> length()

    assert logged_count == 2
  end

  test "does not send events if :dsn is not configured or nil" do
    put_test_config(dsn: nil)
    event = Sentry.Event.transform_exception(%RuntimeError{message: "oops"}, [])
    assert :ignored = Sentry.send_event(event)
  end
end
