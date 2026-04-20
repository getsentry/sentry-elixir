defmodule Sentry.Test.AssertionsTest do
  use ExUnit.Case, async: true

  import Sentry.Test.Assertions

  alias Sentry.Test, as: SentryTest

  # All tests use direct ETS insertion to isolate assertion logic from the
  # event collection pipeline. This avoids stray events from background
  # processes (TelemetryProcessor scheduler) that can bleed in during
  # full suite runs.

  describe "assert_sentry_report/2 auto-pop with :event" do
    setup do
      SentryTest.setup_sentry()
    end

    test "pops exactly 1 event and validates criteria" do
      insert_event(level: :error, message: msg("hello"))

      event =
        assert_sentry_report(:event,
          level: :error,
          message: %{formatted: "hello"}
        )

      assert %Sentry.Event{} = event
    end

    test "validates nested map subset matching" do
      insert_event(level: :error, tags: %{env: "test", region: "us"})

      assert_sentry_report(:event, tags: %{env: "test"})
    end

    test "validates regex matching" do
      insert_event(level: :error, message: msg("hello world"))

      assert_sentry_report(:event, message: %{formatted: ~r/hello/})
    end

    test "returns the matched item for further assertions" do
      insert_event(
        level: :error,
        original_exception: %RuntimeError{message: "boom"}
      )

      event = assert_sentry_report(:event, level: :error)
      assert event.original_exception == %RuntimeError{message: "boom"}
    end

    test "fails when 0 items captured" do
      assert_raise ExUnit.AssertionError, ~r/Expected 1 Sentry event within 10ms, got 0/, fn ->
        assert_sentry_report(:event, level: :error, timeout: 10)
      end
    end

    test "fails when 2+ items captured" do
      insert_event(level: :error, message: msg("first"))
      insert_event(level: :error, message: msg("second"))

      assert_raise ExUnit.AssertionError, ~r/Expected exactly 1 Sentry event, got 2/, fn ->
        assert_sentry_report(:event, level: :error)
      end
    end

    test "fails on field mismatch with clear error" do
      insert_event(level: :error)

      error =
        assert_raise ExUnit.AssertionError, fn ->
          assert_sentry_report(:event, level: :warning)
        end

      assert error.message =~ "Sentry event assertion failed"
      assert error.message =~ ":level"
      assert error.message =~ "expected:"
      assert error.message =~ ":warning"
    end
  end

  describe "assert_sentry_report/2 auto-pop with :transaction" do
    setup do
      SentryTest.setup_sentry()
    end

    test "pops exactly 1 transaction and validates criteria" do
      insert_transaction(span_id: "parent-312")

      assert_sentry_report(:transaction, span_id: "parent-312")
    end
  end

  describe "assert_sentry_report/2 auto-pop with :log" do
    setup do
      SentryTest.setup_sentry()
    end

    test "pops exactly 1 log and validates criteria" do
      insert_log_event(:info, "test log message")

      assert_sentry_report(:log, body: "test log message", level: :info)
    end
  end

  describe "assert_sentry_report/2 with explicit data" do
    test "validates a struct with atom-key criteria" do
      event = build_event(level: :error, message: msg("hello"))

      result = assert_sentry_report(event, level: :error, message: %{formatted: "hello"})
      assert result == event
    end

    test "validates a JSON map with string-key criteria" do
      json_map = %{
        "level" => "error",
        "message" => %{"formatted" => "hello"},
        "tags" => %{"env" => "test", "region" => "us"}
      }

      assert_sentry_report(json_map, [{"level", "error"}, {"tags", %{"env" => "test"}}])
    end

    test "atom-key criteria works on JSON maps via fallback" do
      json_map = %{"level" => "error", "message" => %{"formatted" => "hello"}}

      assert_sentry_report(json_map, level: "error")
    end

    test "unwraps a single-element list" do
      json_map = %{"level" => "error"}

      assert_sentry_report([json_map], [{"level", "error"}])
    end

    test "fails on multi-element list" do
      items = [%{"level" => "error"}, %{"level" => "warning"}]

      assert_raise ExUnit.AssertionError, ~r/Expected exactly 1 Sentry report, got 2/, fn ->
        assert_sentry_report(items, [{"level", "error"}])
      end
    end

    test "fails on empty list" do
      assert_raise ExUnit.AssertionError, ~r/Expected exactly 1 Sentry report, got 0/, fn ->
        assert_sentry_report([], [{"level", "error"}])
      end
    end
  end

  describe "assert_sentry_log/2,3" do
    setup do
      SentryTest.setup_sentry()
    end

    test "finds matching log by level and exact body" do
      insert_log_event(:info, "User session started")

      log = assert_sentry_log(:info, "User session started")
      assert %Sentry.LogEvent{} = log
      assert log.body == "User session started"
    end

    test "finds matching log by level and regex body" do
      insert_log_event(:info, "User session started for user 42")

      log = assert_sentry_log(:info, ~r/session started/)
      assert log.body == "User session started for user 42"
    end

    test "supports extra criteria" do
      insert_log_event(:info, "test message", trace_id: "abc123")

      log = assert_sentry_log(:info, "test message", trace_id: "abc123")
      assert log.trace_id == "abc123"
    end

    test "fails when no matching log found" do
      insert_log_event(:info, "other message")

      assert_raise ExUnit.AssertionError, ~r/No matching Sentry log found/, fn ->
        assert_sentry_log(:error, "nonexistent message", timeout: 10)
      end
    end

    test "skips logs that don't match level" do
      insert_log_event(:info, "hello")

      assert_raise ExUnit.AssertionError, ~r/No matching Sentry log found/, fn ->
        assert_sentry_log(:error, "hello", timeout: 10)
      end
    end
  end

  describe "find_sentry_report!/2" do
    setup do
      SentryTest.setup_sentry()
    end

    test "finds first matching item in a list of structs" do
      insert_event(level: :error, message: msg("first"))
      insert_event(level: :error, message: msg("second"))

      events = SentryTest.pop_sentry_reports()
      event = find_sentry_report!(events, message: %{formatted: "second"})

      assert event.message.formatted == "second"
    end

    test "finds with regex matching" do
      insert_event(level: :error, message: msg("hello world"))
      insert_event(level: :error, message: msg("goodbye world"))

      events = SentryTest.pop_sentry_reports()
      event = find_sentry_report!(events, message: %{formatted: ~r/goodbye/})

      assert event.message.formatted == "goodbye world"
    end

    test "works with JSON maps and string keys" do
      items = [
        %{"level" => "error", "message" => %{"formatted" => "first"}},
        %{"level" => "warning", "message" => %{"formatted" => "second"}}
      ]

      item = find_sentry_report!(items, [{"level", "warning"}])
      assert item["message"]["formatted"] == "second"
    end

    test "atom keys work on JSON maps via fallback" do
      items = [
        %{"level" => "error"},
        %{"level" => "warning"}
      ]

      item = find_sentry_report!(items, level: "warning")
      assert item["level"] == "warning"
    end

    test "fails with descriptive error when no match" do
      insert_event(level: :error, message: msg("hello"))

      events = SentryTest.pop_sentry_reports()

      error =
        assert_raise ExUnit.AssertionError, fn ->
          find_sentry_report!(events, message: %{formatted: "nonexistent"})
        end

      assert error.message =~ "No matching Sentry report found"
      assert error.message =~ "1 item(s)"
    end

    test "fails on empty list" do
      assert_raise ExUnit.AssertionError, ~r/No matching Sentry report found in 0 item/, fn ->
        find_sentry_report!([], level: :error)
      end
    end
  end

  describe "assert_sentry_report/2 auto-pop with :metric" do
    setup do
      SentryTest.setup_sentry()
    end

    test "pops exactly 1 metric and validates criteria" do
      insert_metric(type: :counter, name: "button.clicks", value: 1)

      assert_sentry_report(:metric, type: :counter, name: "button.clicks", value: 1)
    end

    test "validates nested map subset matching" do
      insert_metric(type: :gauge, name: "memory.usage", value: 512, attributes: %{pool: "main"})

      assert_sentry_report(:metric, attributes: %{pool: "main"})
    end

    test "returns the matched item for further assertions" do
      insert_metric(type: :distribution, name: "response.time", value: 42.5, unit: "millisecond")

      metric = assert_sentry_report(:metric, name: "response.time")
      assert metric.type == :distribution
      assert metric.unit == "millisecond"
    end

    test "fails when 0 metrics captured" do
      assert_raise ExUnit.AssertionError, ~r/Expected 1 Sentry metric within 10ms, got 0/, fn ->
        assert_sentry_report(:metric, name: "button.clicks", timeout: 10)
      end
    end

    test "fails on field mismatch with clear error" do
      insert_metric(type: :counter, name: "button.clicks", value: 1)

      error =
        assert_raise ExUnit.AssertionError, fn ->
          assert_sentry_report(:metric, type: :gauge)
        end

      assert error.message =~ "Sentry metric assertion failed"
      assert error.message =~ ":type"
    end
  end

  describe "await behaviour" do
    setup do
      SentryTest.setup_sentry()
    end

    test "polling catches an item inserted mid-wait" do
      table = Process.get(:sentry_test_collector)

      Task.start(fn ->
        Process.sleep(30)
        event = build_event(level: :error)
        :ets.insert(table, {System.unique_integer([:monotonic]), event})
      end)

      assert_sentry_report(:event, level: :error, timeout: 500)
    end

    test ":timeout option is respected when item never arrives" do
      before = System.monotonic_time(:millisecond)

      assert_raise ExUnit.AssertionError, ~r/within 50ms/, fn ->
        assert_sentry_report(:event, level: :error, timeout: 50)
      end

      elapsed = System.monotonic_time(:millisecond) - before
      assert elapsed < 500, "expected fast failure, waited #{elapsed}ms"
    end

    test "assert_sentry_log awaits for a matching log even when non-matching logs arrive first" do
      table = Process.get(:sentry_test_collector)
      now = System.system_time(:microsecond) / 1_000_000

      Task.start(fn ->
        Process.sleep(10)
        noise = struct!(Sentry.LogEvent, level: :info, body: "unrelated", timestamp: now)
        :ets.insert(table, {System.unique_integer([:monotonic]), noise})

        Process.sleep(30)
        target = struct!(Sentry.LogEvent, level: :info, body: "target log", timestamp: now)
        :ets.insert(table, {System.unique_integer([:monotonic]), target})
      end)

      log = assert_sentry_log(:info, "target log", timeout: 500)
      assert log.body == "target log"
    end

    test "maybe_flush is a no-op when no processor is registered in pdict" do
      Process.delete(:sentry_telemetry_processor)
      refute Process.get(:sentry_telemetry_processor)

      insert_event(level: :error)
      assert_sentry_report(:event, level: :error)
    end
  end

  describe "integration with real event pipeline" do
    setup do
      SentryTest.setup_sentry()
    end

    test "assert_sentry_report works with captured events" do
      Sentry.capture_message("integration test", result: :sync)

      events = SentryTest.pop_sentry_reports()
      event = find_sentry_report!(events, message: %{formatted: "integration test"})
      assert event.level == :error
    end

    test "assert_sentry_report works with captured transactions" do
      tx =
        Sentry.Transaction.new(%{
          span_id: "int-test-span",
          start_timestamp: "2025-01-01T00:00:00Z",
          timestamp: "2025-01-02T02:03:00Z",
          contexts: %{trace: %{trace_id: "trace-int", span_id: "int-test-span"}},
          spans: []
        })

      Sentry.send_transaction(tx, result: :sync)

      txs = SentryTest.pop_sentry_transactions()
      found = find_sentry_report!(txs, span_id: "int-test-span")
      assert %Sentry.Transaction{} = found
    end
  end

  # Test helpers — direct ETS insertion for isolation

  defp msg(text) do
    %Sentry.Interfaces.Message{formatted: text}
  end

  defp build_event(attrs) do
    defaults = %{
      event_id: Sentry.UUID.uuid4_hex(),
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      platform: :elixir
    }

    struct!(Sentry.Event, Map.merge(defaults, Map.new(attrs)))
  end

  defp insert_event(attrs) do
    event = build_event(attrs)
    table = Process.get(:sentry_test_collector)
    :ets.insert(table, {System.unique_integer([:monotonic]), event})
    event
  end

  defp insert_transaction(attrs) do
    defaults = %{
      event_id: Sentry.UUID.uuid4_hex(),
      span_id: "default-span",
      start_timestamp: "2025-01-01T00:00:00Z",
      timestamp: "2025-01-02T02:03:00Z",
      contexts: %{trace: %{trace_id: "trace-default", span_id: "default-span"}},
      spans: [],
      platform: "elixir"
    }

    tx = struct!(Sentry.Transaction, Map.merge(defaults, Map.new(attrs)))
    table = Process.get(:sentry_test_collector)
    :ets.insert(table, {System.unique_integer([:monotonic]), tx})
    tx
  end

  defp insert_log_event(level, body, extra \\ []) do
    log_event =
      struct!(
        Sentry.LogEvent,
        Keyword.merge(
          [level: level, body: body, timestamp: System.system_time(:microsecond) / 1_000_000],
          extra
        )
      )

    table = Process.get(:sentry_test_collector)
    :ets.insert(table, {System.unique_integer([:monotonic]), log_event})
    log_event
  end

  defp insert_metric(attrs) do
    defaults = [
      type: :counter,
      name: "test.metric",
      value: 1,
      timestamp: System.system_time(:nanosecond) / 1_000_000_000
    ]

    metric = struct!(Sentry.Metric, Keyword.merge(defaults, attrs))
    table = Process.get(:sentry_test_collector)
    :ets.insert(table, {System.unique_integer([:monotonic]), metric})
    metric
  end
end
