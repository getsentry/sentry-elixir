defmodule SentryTest do
  use Sentry.Case

  require OpenTelemetry.Tracer, as: Tracer

  import ExUnit.CaptureLog
  import Sentry.Test.Assertions
  import Sentry.TestHelpers

  alias Sentry.Test, as: SentryTest

  defmodule TestFilter do
    @behaviour Sentry.EventFilter

    def exclude_exception?(%ArithmeticError{}, :plug), do: true
    def exclude_exception?(_, _), do: false
  end

  defmodule RaisingFilter do
    @behaviour Sentry.EventFilter

    def exclude_exception?(_exception, _source), do: raise("filter is broken")
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

    assert {:error, %Sentry.ClientError{reason: {:request_failure, error}}} =
             Sentry.capture_message("error", request_retries: [], result: :sync)

    assert %{reason: :timeout} = error

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

  test "reads Retry-After response headers case-insensitively", %{bypass: bypass} do
    request_count = :counters.new(1, [])
    put_test_config(client: Sentry.FinchClient)

    Bypass.expect(bypass, "POST", "/api/1/envelope/", fn conn ->
      request_number = :counters.get(request_count, 1)
      :counters.add(request_count, 1, 1)

      if request_number == 0 do
        conn
        |> Plug.Conn.put_resp_header("Retry-After", "0")
        |> Plug.Conn.resp(429, ~s<{}>)
      else
        Plug.Conn.resp(conn, 200, ~s<{"id": "#{Sentry.UUID.uuid4_hex()}"}>)
      end
    end)

    assert {:error, %Sentry.ClientError{reason: :rate_limited}} =
             Sentry.capture_message("rate-limited", result: :sync, request_retries: [])

    assert {:ok, _event_id} =
             Sentry.capture_message("accepted", result: :sync, request_retries: [])

    assert :counters.get(request_count, 1) == 2
  end

  describe "a :before_send callback that crashes" do
    test "drops the event and returns :excluded when the callback raises" do
      put_test_config(before_send: fn _event -> raise "before_send is broken" end)

      log =
        capture_log(fn ->
          assert :excluded = Sentry.capture_message("raising before_send", result: :sync)
        end)

      assert log =~ ":before_send callback failed"
      assert log =~ "before_send is broken"
      assert SentryTest.pop_sentry_reports() == []
    end

    test "drops the event and returns :excluded when the callback throws" do
      put_test_config(before_send: fn _event -> throw(:before_send_is_broken) end)

      log =
        capture_log(fn ->
          assert :excluded = Sentry.capture_message("throwing before_send", result: :sync)
        end)

      assert log =~ ":before_send callback failed"
      assert log =~ "before_send_is_broken"
      assert SentryTest.pop_sentry_reports() == []
    end

    test "drops the exception and returns :excluded when the callback exits" do
      put_test_config(before_send: fn _event -> exit(:before_send_is_broken) end)

      log =
        capture_log(fn ->
          assert :excluded =
                   Sentry.capture_exception(%RuntimeError{message: "oops"}, result: :sync)
        end)

      assert log =~ ":before_send callback failed"
      assert log =~ "before_send_is_broken"
      assert SentryTest.pop_sentry_reports() == []
    end

    test "drops the transaction and returns :excluded" do
      transaction = create_transaction(%{transaction: "crashing-before-send-transaction"})

      log =
        capture_log(fn ->
          assert :excluded =
                   Sentry.send_transaction(transaction,
                     result: :sync,
                     before_send: fn _transaction -> exit(:before_send_is_broken) end
                   )
        end)

      assert log =~ ":before_send callback failed"
      assert SentryTest.pop_sentry_reports() == []
    end

    test "does not report its own failure back to Sentry" do
      test_pid = self()
      ref = make_ref()
      handler_name = :"sentry_handler_#{System.unique_integer([:positive])}"

      :ok =
        :logger.add_handler(handler_name, Sentry.LoggerHandler, %{
          config: %{capture_log_messages: true, level: :debug}
        })

      on_exit(fn -> _ = :logger.remove_handler(handler_name) end)

      put_test_config(
        before_send: fn _event ->
          send(test_pid, {ref, :called})
          raise "before_send is broken"
        end
      )

      capture_log(fn ->
        assert :excluded = Sentry.capture_message("self-reporting before_send", result: :sync)
      end)

      assert_received {^ref, :called}
      refute_received {^ref, :called}
    end
  end

  describe "an :after_send_event callback that crashes" do
    test "still returns the successful send result for an event" do
      put_test_config(after_send_event: fn _event, _result -> raise "after_send is broken" end)

      log =
        capture_log(fn ->
          assert {:ok, _id} = Sentry.capture_message("raising after_send", result: :sync)
        end)

      assert log =~ ":after_send_event callback failed"
      assert log =~ "after_send is broken"

      assert_sentry_report(:event, message: %{formatted: "raising after_send"})
    end

    test "still returns the successful send result for a transaction" do
      transaction = create_transaction(%{transaction: "crashing-after-send-transaction"})

      log =
        capture_log(fn ->
          assert {:ok, _id} =
                   Sentry.send_transaction(transaction,
                     result: :sync,
                     after_send_event: fn _transaction, _result -> exit(:after_send_is_broken) end
                   )
        end)

      assert log =~ ":after_send_event callback failed"
      assert log =~ "after_send_is_broken"

      assert_sentry_report(:transaction, transaction: "crashing-after-send-transaction")
    end
  end

  describe "a :filter callback that crashes" do
    test "drops the exception and returns :excluded when the filter raises" do
      put_test_config(filter: RaisingFilter)

      log =
        capture_log(fn ->
          assert :excluded =
                   Sentry.capture_exception(%RuntimeError{message: "oops"}, result: :sync)
        end)

      assert log =~ ":filter callback failed"
      assert log =~ "filter is broken"
      assert SentryTest.pop_sentry_reports() == []
    end

    test "drops the exception and returns :excluded when the filter cannot be called" do
      put_test_config(filter: __MODULE__.MissingFilter)

      log =
        capture_log(fn ->
          assert :excluded =
                   Sentry.capture_exception(%RuntimeError{message: "oops"}, result: :sync)
        end)

      assert log =~ ":filter callback failed"
      assert SentryTest.pop_sentry_reports() == []
    end
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

    test "does not apply categorized error rate limits to transactions", %{
      bypass: bypass,
      transaction: transaction
    } do
      test_pid = self()
      ref = make_ref()
      request_count = :counters.new(1, [])
      put_test_config(client: Sentry.FinchClient)

      Bypass.expect(bypass, "POST", "/api/1/envelope/", fn conn ->
        request_number = :counters.get(request_count, 1)
        :counters.add(request_count, 1, 1)

        if request_number == 0 do
          conn
          |> Plug.Conn.put_resp_header("X-Sentry-Rate-Limits", "60:error:organization")
          |> Plug.Conn.resp(429, ~s<{"error": "Rate limited"}>)
        else
          {:ok, body, conn} = Plug.Conn.read_body(conn)

          if body =~ ~s("type":"transaction") do
            send(test_pid, {:bypass_envelope, ref, body})
          end

          Plug.Conn.resp(conn, 200, ~s<{"id": "#{Sentry.UUID.uuid4_hex()}"}>)
        end
      end)

      assert {:error, %Sentry.ClientError{reason: :rate_limited}} =
               Sentry.capture_message(
                 "rate-limited-error",
                 result: :sync,
                 request_retries: []
               )

      assert {:ok, _event_id} =
               Sentry.send_transaction(transaction, result: :sync, request_retries: [])

      assert_sentry_transaction(ref, transaction: "test-transaction")
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
        SentryTest.collect_sentry_transactions(ref, 1),
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

  describe "trace context on captured errors without tracing" do
    test "sends the error without a trace context when nothing is being traced", %{bypass: bypass} do
      ref = SentryTest.setup_bypass_envelope_collector(bypass, type: "event")

      assert {:ok, _} = Sentry.capture_message("standalone failure", result: :sync)

      assert [event] = extract_events(collect_envelopes(ref, 1))
      refute event["contexts"]["trace"]
    end
  end

  describe "trace context on captured errors" do
    setup %{bypass: bypass} do
      put_test_config(traces_sample_rate: 1.0)
      %{ref: SentryTest.setup_bypass_envelope_collector(bypass)}
    end

    test "sends the error and the transaction of the same operation with the same trace_id", %{
      ref: ref
    } do
      Tracer.with_span "checkout" do
        assert {:ok, _} = Sentry.capture_message("checkout failed", result: :sync)
      end

      envelopes = collect_envelopes(ref, 2, timeout: 2000)

      assert [event] = extract_events(envelopes)
      assert [transaction] = extract_transactions(envelopes)

      assert event["contexts"]["trace"]["trace_id"] ==
               transaction["contexts"]["trace"]["trace_id"]
    end

    test "points the error at the span it was captured in", %{ref: ref} do
      Tracer.with_span "checkout" do
        Tracer.with_span "charge_card" do
          assert {:ok, _} = Sentry.capture_message("charge failed", result: :sync)
        end
      end

      envelopes = collect_envelopes(ref, 2, timeout: 2000)

      assert [event] = extract_events(envelopes)
      assert [transaction] = extract_transactions(envelopes)
      assert [child_span] = transaction["spans"]

      assert event["contexts"]["trace"]["span_id"] == child_span["span_id"]
    end
  end

  describe "flush/1" do
    test "warns and returns :ok when the TelemetryProcessor is not running" do
      # The default TelemetryProcessor runs under the application supervisor, so it has
      # to be taken down to reach the :noproc path.
      :ok = Supervisor.terminate_child(Sentry.Supervisor, Sentry.TelemetryProcessor)

      on_exit(fn ->
        {:ok, _} = Supervisor.restart_child(Sentry.Supervisor, Sentry.TelemetryProcessor)
      end)

      log =
        capture_log([metadata: [:domain]], fn ->
          assert :ok = Sentry.flush()
        end)

      assert log =~ "Sentry.flush/1 failed: TelemetryProcessor not running"
      assert log =~ ~r/domain=(\w+\.)*sentry/
      refute log =~ "failed unexpectedly"
    end
  end
end
