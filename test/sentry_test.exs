defmodule SentryTest do
  use Sentry.Case

  import ExUnit.CaptureLog
  import Sentry.Test.Assertions
  import Sentry.TestHelpers

  alias Sentry.Test, as: SentryTest

  defmodule TestFilter do
    @behaviour Sentry.EventFilter

    def exclude_exception?(%ArithmeticError{}, :plug), do: true
    def exclude_exception?(_, _), do: false
  end

  setup do
    SentryTest.setup_sentry(dedup_events: false)
  end

  test "excludes events properly" do
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

    events = SentryTest.pop_sentry_reports()
    assert length(events) == 2
    find_sentry_report!(events, original_exception: %RuntimeError{message: "error"})
  end

  @tag :capture_log
  test "errors when taking too long to receive response", %{bypass: bypass} do
    Bypass.expect(bypass, "POST", "/api/1/envelope/", fn _conn ->
      Process.sleep(:infinity)
    end)

    put_test_config(finch_request_opts: [receive_timeout: 50])

    assert {:error,
            %Sentry.ClientError{
              reason: {:request_failure, %Mint.TransportError{reason: :timeout}}
            }} =
             Sentry.capture_message("error", request_retries: [], result: :sync)

    Bypass.pass(bypass)
  end

  test "sets last_event_id_and_source when an event is sent" do
    Sentry.capture_message("test")

    assert_sentry_report(:event, message: %{formatted: "test"})
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

  test "doesn't incur into infinite logging loops because we prevent that" do
    put_test_config(dedup_events: true)
    message_to_report = "Hello #{System.unique_integer([:positive])}"

    :ok =
      :logger.add_handler(:sentry_handler, Sentry.LoggerHandler, %{
        config: %{capture_log_messages: true, level: :debug}
      })

    on_exit(fn ->
      _ = :logger.remove_handler(:sentry_handler)
    end)

    # First one is reported correctly as it has no duplicates
    assert {:ok, _} = Sentry.capture_message(message_to_report)

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

  test "raises error with validate_and_ignore/1 in dev mode if opts passed are invalid " do
    put_test_config(dsn: nil)

    assert_raise NimbleOptions.ValidationError, fn ->
      NimbleOptions.validate!(
        [client: [bad_key: :nada]],
        Sentry.Options.send_event_schema()
      )
    end

    assert [client: :hackney] =
             NimbleOptions.validate!(
               [client: :hackney],
               Sentry.Options.send_event_schema()
             )
  end

  test "does not send events if :dsn is not configured or nil" do
    put_test_config(dsn: nil)
    event = Sentry.Event.transform_exception(%RuntimeError{message: "oops"}, [])
    assert :ignored = Sentry.send_event(event)
  end

  describe "send_check_in/1" do
    test "posts a check-in with all the explicit arguments", %{bypass: bypass} do
      put_test_config(environment_name: "test", release: "1.3.2")
      ref = SentryTest.setup_bypass_envelope_collector(bypass, type: "check_in")

      assert {:ok, _} =
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

      [[{headers, check_in_body}]] = SentryTest.collect_envelopes(ref, 1)

      assert headers["type"] == "check_in"
      assert Map.has_key?(headers, "length")

      assert_sentry_report(check_in_body,
        status: "in_progress",
        monitor_slug: "my-slug",
        duration: 123.2,
        release: "1.3.2",
        environment: "test",
        monitor_config: %{
          "schedule" => %{"type" => "crontab", "value" => "0 * * * *"},
          "checkin_margin" => 5,
          "max_runtime" => 30,
          "failure_issue_threshold" => 2,
          "recovery_threshold" => 2,
          "timezone" => "America/Los_Angeles"
        }
      )
    end

    test "posts a check-in with default arguments", %{bypass: bypass} do
      put_test_config(environment_name: "test", release: "1.3.2")
      ref = SentryTest.setup_bypass_envelope_collector(bypass, type: "check_in")

      assert {:ok, _} = Sentry.capture_check_in(status: :ok, monitor_slug: "default-slug")

      [[{headers, check_in_body}]] = SentryTest.collect_envelopes(ref, 1)

      assert headers["type"] == "check_in"
      assert Map.has_key?(headers, "length")

      assert_sentry_report(check_in_body,
        status: "ok",
        monitor_slug: "default-slug",
        duration: nil,
        release: "1.3.2",
        environment: "test"
      )
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

  describe "send_transaction/2" do
    setup do
      transaction =
        create_transaction(%{
          transaction: "test-transaction",
          contexts: %{
            trace: %{
              trace_id: "trace-id",
              span_id: "root-span"
            }
          },
          spans: [
            %Sentry.Interfaces.Span{
              span_id: "root-span",
              trace_id: "trace-id",
              start_timestamp: 1_234_567_891.123_456,
              timestamp: 1_234_567_891.123_456
            }
          ]
        })

      {:ok, transaction: transaction}
    end

    test "sends transaction to Sentry when configured properly", %{transaction: transaction} do
      assert {:ok, _} = Sentry.send_transaction(transaction)

      assert_sentry_report(:transaction, transaction: "test-transaction")
    end

    test "validates options", %{transaction: transaction} do
      assert_raise NimbleOptions.ValidationError, fn ->
        Sentry.send_transaction(transaction, client: "oops")
      end
    end

    test "ignores transaction when dsn is not configured", %{transaction: transaction} do
      put_test_config(dsn: nil)

      assert :ignored = Sentry.send_transaction(transaction)
    end

    test "respects sample_rate option", %{transaction: transaction} do
      assert {:ok, _} = Sentry.send_transaction(transaction, sample_rate: 1.0)

      assert_sentry_report(:transaction, transaction: "test-transaction")
    end

    test "supports before_send option", %{bypass: bypass, transaction: transaction} do
      # Exclude transaction
      assert :excluded =
               Sentry.send_transaction(transaction, before_send: fn _transaction -> false end)

      # Modify transaction — passing before_send as a per-call option bypasses
      # the collecting callback installed by setup_sentry, so use the envelope
      # collector to assert on the wire payload instead.
      ref = SentryTest.setup_bypass_envelope_collector(bypass, type: "transaction")

      assert {:ok, _} =
               Sentry.send_transaction(
                 transaction,
                 before_send: fn transaction ->
                   %{transaction | transaction: "modified-transaction"}
                 end
               )

      assert_sentry_report(
        SentryTest.collect_envelopes(ref, 1) |> SentryTest.extract_transactions(),
        transaction: "modified-transaction"
      )
    end

    test "supports after_send_event option", %{transaction: transaction} do
      parent = self()

      assert {:ok, id} =
               Sentry.send_transaction(
                 transaction,
                 after_send_event: fn transaction, {:ok, id} ->
                   send(parent, {:after_send, transaction.transaction, id})
                 end
               )

      assert_receive {:after_send, "test-transaction", ^id}
    end

    test "includes release in transaction payload when configured" do
      put_test_config(release: "1.9.123")

      transaction =
        create_transaction(%{
          transaction: "transaction-with-release",
          contexts: %{
            trace: %{
              trace_id: "trace-id",
              span_id: "root-span"
            }
          }
        })

      assert {:ok, _} = Sentry.send_transaction(transaction)

      assert_sentry_report(:transaction,
        transaction: "transaction-with-release",
        release: "1.9.123"
      )
    end
  end

  describe "flush/1" do
    test "returns :ok silently when TelemetryProcessor is not running" do
      # Default TelemetryProcessor is not started in test — this is the :noproc path
      log =
        capture_log(fn ->
          assert :ok = Sentry.flush()
        end)

      refute log =~ "failed unexpectedly"
    end
  end
end
