defmodule Sentry.TestTest do
  use Sentry.Case, async: false

  import Sentry.Test.Assertions

  alias Sentry.Test, as: SentryTest

  describe "setup_sentry/1" do
    test "opens Bypass and configures DSN" do
      %{bypass: bypass} = SentryTest.setup_sentry()

      dsn = Sentry.Config.dsn()
      assert dsn.endpoint_uri =~ "localhost:#{bypass.port}"
    end

    test "accepts extra config options" do
      SentryTest.setup_sentry(dedup_events: false)

      assert Sentry.Config.dedup_events?() == false
    end
  end

  describe "start_collecting_sentry_reports/0" do
    test "works as ExUnit setup callback" do
      assert :ok = SentryTest.start_collecting_sentry_reports()
    end

    test "accepts context map for ExUnit setup compatibility" do
      assert :ok = SentryTest.start_collecting_sentry_reports(%{})
    end
  end

  describe "pop_sentry_reports/0" do
    setup do
      SentryTest.setup_sentry()
    end

    test "returns events from capture_exception" do
      assert {:ok, _} =
               Sentry.capture_exception(%RuntimeError{message: "boom"}, result: :sync)

      assert [%Sentry.Event{} = event] = SentryTest.pop_sentry_reports()
      assert event.original_exception == %RuntimeError{message: "boom"}
    end

    test "returns events from capture_message" do
      assert {:ok, _} = Sentry.capture_message("hello", result: :sync)

      assert [%Sentry.Event{} = event] = SentryTest.pop_sentry_reports()
      assert event.message.formatted == "hello"
    end

    test "returns full struct data including non-payload fields" do
      assert {:ok, _} =
               Sentry.capture_exception(%RuntimeError{message: "test"},
                 result: :sync,
                 event_source: :plug
               )

      assert [%Sentry.Event{} = event] = SentryTest.pop_sentry_reports()
      assert event.original_exception == %RuntimeError{message: "test"}
      assert event.source == :plug
    end

    test "returns multiple events" do
      assert {:ok, _} = Sentry.capture_message("first", result: :sync)
      assert {:ok, _} = Sentry.capture_message("second", result: :sync)

      events = SentryTest.pop_sentry_reports()
      assert length(events) == 2
      assert [first, second] = events
      assert first.message.formatted == "first"
      assert second.message.formatted == "second"
    end

    test "clears events after pop" do
      assert {:ok, _} = Sentry.capture_message("hello", result: :sync)

      assert [_event] = SentryTest.pop_sentry_reports()
      assert [] == SentryTest.pop_sentry_reports()
    end

    test "returns empty list when no events" do
      assert [] == SentryTest.pop_sentry_reports()
    end

    test "captures events from child processes" do
      test_pid = self()

      {:ok, _child_pid} =
        Task.start_link(fn ->
          assert {:ok, _} = Sentry.capture_message("from child", result: :sync)
          send(test_pid, :done)
        end)

      # Ensure the child is recognized as a caller descendant
      # (Task.start_link propagates $callers)
      assert_receive :done, 5000

      events = SentryTest.pop_sentry_reports()
      assert length(events) == 1
      assert [event] = events
      assert event.message.formatted == "from child"
    end
  end

  describe "pop_sentry_transactions/0" do
    setup do
      SentryTest.setup_sentry()
    end

    test "returns transactions" do
      transaction =
        Sentry.Transaction.new(%{
          span_id: "parent-312",
          start_timestamp: "2025-01-01T00:00:00Z",
          timestamp: "2025-01-02T02:03:00Z",
          contexts: %{
            trace: %{
              trace_id: "trace-312",
              span_id: "parent-312"
            }
          },
          spans: []
        })

      assert {:ok, _} = Sentry.send_transaction(transaction, result: :sync)

      assert [%Sentry.Transaction{} = collected] = SentryTest.pop_sentry_transactions()
      assert collected.span_id == "parent-312"
    end

    test "does not mix events and transactions" do
      assert {:ok, _} = Sentry.capture_message("event", result: :sync)

      transaction =
        Sentry.Transaction.new(%{
          span_id: "tx-1",
          start_timestamp: "2025-01-01T00:00:00Z",
          timestamp: "2025-01-02T02:03:00Z",
          contexts: %{trace: %{trace_id: "t-1", span_id: "tx-1"}},
          spans: []
        })

      assert {:ok, _} = Sentry.send_transaction(transaction, result: :sync)

      assert [%Sentry.Event{}] = SentryTest.pop_sentry_reports()
      assert [%Sentry.Transaction{}] = SentryTest.pop_sentry_transactions()
    end
  end

  describe "deprecated functions" do
    setup do
      SentryTest.setup_sentry()
    end

    test "allow_sentry_reports/2 is a no-op" do
      assert :ok = SentryTest.allow_sentry_reports(self(), self())
    end

    test "start_collecting/1 is a no-op when already collecting" do
      assert :ok = SentryTest.start_collecting()
    end

    test "cleanup/1 is a no-op" do
      assert :ok = SentryTest.cleanup(self())
    end
  end

  describe "before_send wrapping" do
    test "wraps existing before_send callback" do
      test_pid = self()

      SentryTest.setup_sentry(
        before_send: fn event ->
          send(test_pid, {:before_send_called, event.message.formatted})
          event
        end
      )

      assert {:ok, _} = Sentry.capture_message("wrapped", result: :sync)

      # The original callback should have been called
      assert_receive {:before_send_called, "wrapped"}

      # And the event should still be collected
      assert [%Sentry.Event{}] = SentryTest.pop_sentry_reports()
    end

    test "does not collect event when before_send returns nil" do
      SentryTest.setup_sentry(before_send: fn _event -> nil end)

      assert :excluded = Sentry.capture_message("dropped", result: :sync)

      assert [] == SentryTest.pop_sentry_reports()
    end

    test "wraps {module, function} callback" do
      defmodule BeforeSendMFA do
        def callback(event) do
          %{event | fingerprint: ["custom"]}
        end
      end

      SentryTest.setup_sentry(before_send: {BeforeSendMFA, :callback})

      assert {:ok, _} = Sentry.capture_message("mfa test", result: :sync)

      assert [%Sentry.Event{} = event] = SentryTest.pop_sentry_reports()
      assert event.fingerprint == ["custom"]
    end
  end

  describe "pop_sentry_logs/0" do
    @describetag :capture_log

    setup %{telemetry_processor: telemetry_processor} do
      ctx = SentryTest.setup_sentry(enable_logs: true, logs: [level: :info])

      handler_name = :"sentry_logs_test_#{System.unique_integer([:positive])}"

      handler_config = %{
        config: %{
          telemetry_processor: telemetry_processor,
          enable_logs: true
        }
      }

      :ok = :logger.add_handler(handler_name, Sentry.LoggerHandler, handler_config)

      on_exit(fn ->
        _ = :logger.remove_handler(handler_name)
      end)

      ctx
    end

    test "collects log events via the TelemetryProcessor pipeline" do
      require Logger

      Logger.info("pop_sentry_logs test message")

      Sentry.TelemetryProcessor.flush()

      assert_sentry_log(:info, "pop_sentry_logs test message")
    end
  end
end
