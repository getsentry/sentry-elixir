defmodule Sentry.TestBackwardCompatTest do
  use Sentry.Case, async: false

  alias Sentry.Test, as: SentryTest

  describe "original behavior without setup_sentry" do
    test "capture_exception returns {:ok, \"\"}" do
      assert {:ok, ""} = Sentry.capture_exception(%RuntimeError{message: "boom"}, result: :sync)
    end

    test "capture_message returns {:ok, \"\"}" do
      assert {:ok, ""} = Sentry.capture_message("hello", result: :sync)
    end
  end

  describe "original helper workflow" do
    test "start_collecting_sentry_reports then pop_sentry_reports" do
      assert :ok = SentryTest.start_collecting_sentry_reports()

      assert {:ok, ""} =
               Sentry.capture_exception(%RuntimeError{message: "collected"}, result: :sync)

      assert {:ok, ""} = Sentry.capture_message("also collected", result: :sync)

      events = SentryTest.pop_sentry_reports()
      assert length(events) == 2
      assert Enum.any?(events, &(&1.original_exception == %RuntimeError{message: "collected"}))
      assert Enum.any?(events, &match?(%{message: %{formatted: "also collected"}}, &1))
    end

    test "start_collecting_sentry_reports then pop_sentry_transactions" do
      assert :ok = SentryTest.start_collecting_sentry_reports()

      transaction =
        Sentry.Transaction.new(%{
          span_id: "compat-span",
          start_timestamp: "2025-01-01T00:00:00Z",
          timestamp: "2025-01-02T00:00:00Z",
          contexts: %{trace: %{trace_id: "compat-trace", span_id: "compat-span"}},
          spans: []
        })

      assert {:ok, ""} = Sentry.send_transaction(transaction, result: :sync)

      assert [%Sentry.Transaction{} = collected] = SentryTest.pop_sentry_transactions()
      assert collected.span_id == "compat-span"
    end

    test "events and transactions are kept separate" do
      assert :ok = SentryTest.start_collecting_sentry_reports()

      assert {:ok, ""} = Sentry.capture_message("an event", result: :sync)

      transaction =
        Sentry.Transaction.new(%{
          span_id: "sep-span",
          start_timestamp: "2025-01-01T00:00:00Z",
          timestamp: "2025-01-02T00:00:00Z",
          contexts: %{trace: %{trace_id: "sep-trace", span_id: "sep-span"}},
          spans: []
        })

      assert {:ok, ""} = Sentry.send_transaction(transaction, result: :sync)

      assert [%Sentry.Event{}] = SentryTest.pop_sentry_reports()
      assert [%Sentry.Transaction{}] = SentryTest.pop_sentry_transactions()
    end

    test "pop clears collected items" do
      assert :ok = SentryTest.start_collecting_sentry_reports()

      assert {:ok, ""} = Sentry.capture_message("once", result: :sync)
      assert [_] = SentryTest.pop_sentry_reports()
      assert [] == SentryTest.pop_sentry_reports()
    end
  end
end
