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

  test "does not send events if :dsn is not configured or nil (if not in test mode)" do
    put_test_config(dsn: nil, test_mode: false)
    event = Sentry.Event.transform_exception(%RuntimeError{message: "oops"}, [])
    assert :ignored = Sentry.send_event(event)
  end

  test "if in test mode, swallows events if the :dsn is nil" do
    put_test_config(dsn: nil, test_mode: true)
    event = Sentry.Event.transform_exception(%RuntimeError{message: "oops"}, [])
    assert {:ok, ""} = Sentry.send_event(event)
  end

  describe "send_check_in/1" do
    test "posts a check-in with all the explicit arguments", %{bypass: bypass} do
      put_test_config(environment_name: "test", release: "1.3.2")

      Bypass.expect_once(bypass, "POST", "/api/1/envelope/", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert [{headers, check_in_body}] = decode_envelope!(body)

        assert headers["type"] == "check_in"
        assert Map.has_key?(headers, "length")

        assert check_in_body["status"] == "in_progress"
        assert check_in_body["monitor_slug"] == "my-slug"
        assert check_in_body["duration"] == 123.2
        assert check_in_body["release"] == "1.3.2"
        assert check_in_body["environment"] == "test"

        assert check_in_body["monitor_config"] == %{
                 "schedule" => %{"type" => "crontab", "value" => "0 * * * *"},
                 "checkin_margin" => 5,
                 "max_runtime" => 30,
                 "failure_issue_threshold" => 2,
                 "recovery_threshold" => 2,
                 "timezone" => "America/Los_Angeles"
               }

        Plug.Conn.send_resp(conn, 200, ~s<{"id": "1923"}>)
      end)

      assert {:ok, "1923"} =
               Sentry.capture_check_in(
                 status: :in_progress,
                 monitor_slug: "my-slug",
                 duration: 123.2,
                 monitor_config: [
                   schedule: [
                     type: :crontab,
                     value: "0 * * * *"
                   ],
                   checkin_margin: 5,
                   max_runtime: 30,
                   failure_issue_threshold: 2,
                   recovery_threshold: 2,
                   timezone: "America/Los_Angeles"
                 ]
               )
    end

    test "posts a check-in with default arguments", %{bypass: bypass} do
      put_test_config(environment_name: "test", release: "1.3.2")

      Bypass.expect_once(bypass, "POST", "/api/1/envelope/", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert [{headers, check_in_body}] = decode_envelope!(body)

        assert headers["type"] == "check_in"
        assert Map.has_key?(headers, "length")

        assert check_in_body["status"] == "ok"
        assert check_in_body["monitor_slug"] == "default-slug"
        assert Map.fetch!(check_in_body, "duration") == nil
        assert Map.fetch!(check_in_body, "release") == "1.3.2"
        assert Map.fetch!(check_in_body, "environment") == "test"

        Plug.Conn.send_resp(conn, 200, ~s<{"id": "1923"}>)
      end)

      assert {:ok, "1923"} = Sentry.capture_check_in(status: :ok, monitor_slug: "default-slug")
    end
  end

  describe "get_dsn/0" do
    test "returns nil if the :dsn option is not configured" do
      put_test_config(dsn: nil)
      assert Sentry.get_dsn() == nil
    end

    test "returns the DSN if it's configured" do
      random_string = fn -> 5 |> :crypto.strong_rand_bytes() |> Base.encode16() end

      random_dsn =
        "https://#{random_string.()}:#{random_string.()}@#{random_string.()}:3000/#{System.unique_integer([:positive])}"

      put_test_config(dsn: random_dsn)
      assert Sentry.get_dsn() == random_dsn
    end
  end
end
