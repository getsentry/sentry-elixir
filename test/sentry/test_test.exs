defmodule Sentry.TestTest do
  use Sentry.Case, async: false

  require Logger

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

    test "tags the per-test telemetry scheduler for buffered event routing" do
      %{telemetry_processor: processor_name} = SentryTest.setup_sentry()
      scheduler_pid = Sentry.TelemetryProcessor.get_scheduler(processor_name)

      assert Sentry.Test.Registry.lookup_processor_for(scheduler_pid) == processor_name
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

    test "start_collecting/1 is a no-op when already collecting" do
      assert :ok = SentryTest.start_collecting()
    end

    test "cleanup/1 is a no-op" do
      assert :ok = SentryTest.cleanup(self())
    end
  end

  describe "allow_sentry_reports/2 (issue #1052)" do
    setup do
      SentryTest.setup_sentry()
    end

    test "events from a process without $callers are not collected" do
      test_pid = self()

      pid =
        spawn(fn ->
          assert [] == Process.get(:"$callers", [])
          assert {:ok, _} = Sentry.capture_message("from unrelated process", result: :sync)
          send(test_pid, :done)
        end)

      ref = Process.monitor(pid)
      assert_receive :done, 5000
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5000

      assert SentryTest.pop_sentry_reports() == []
    end

    test "allow_sentry_reports/2 should let an unrelated process report into the test" do
      test_pid = self()

      pid =
        spawn(fn ->
          receive do
            :go ->
              assert {:ok, _} = Sentry.capture_message("from allowed process", result: :sync)
              send(test_pid, :done)
          end
        end)

      ref = Process.monitor(pid)

      assert :ok = SentryTest.allow_sentry_reports(self(), pid)

      send(pid, :go)
      assert_receive :done, 5000
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5000

      assert [%Sentry.Event{} = event] = SentryTest.pop_sentry_reports()
      assert event.message.formatted == "from allowed process"
    end

    test "allow_sentry_reports/2 is idempotent under the same owner" do
      pid = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> Process.exit(pid, :kill) end)

      assert :ok = SentryTest.allow_sentry_reports(self(), pid)
      assert :ok = SentryTest.allow_sentry_reports(self(), pid)
    end

    test "allow_sentry_reports/2 accepts a zero-arity function returning a pid" do
      pid = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> Process.exit(pid, :kill) end)

      assert :ok = SentryTest.allow_sentry_reports(self(), fn -> pid end)
    end

    test "allow_sentry_reports/2 raises when the function does not return a pid" do
      assert_raise ArgumentError, ~r/expected the function .* to return a pid/, fn ->
        SentryTest.allow_sentry_reports(self(), fn -> :not_a_pid end)
      end
    end
  end

  describe "allow_sentry_reports/2 without setup" do
    test "raises a descriptive ArgumentError when owner has not called setup_sentry/1" do
      pid = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> Process.exit(pid, :kill) end)

      assert_raise ArgumentError, ~r/is not collecting Sentry reports/, fn ->
        SentryTest.allow_sentry_reports(self(), pid)
      end
    end
  end

  describe "allow_sentry_reports/2 cross-test isolation" do
    setup do
      SentryTest.setup_sentry()
    end

    defp spawn_peer_owner(target, parent) do
      spawn(fn ->
        {:ok, _} =
          NimbleOwnership.get_and_update(
            Sentry.Test.OwnershipServer,
            self(),
            Sentry.Test.Registry.scope_key(),
            fn _ -> {:ok, Sentry.Test.Registry.collector_metadata(:peer_table)} end
          )

        :ok =
          NimbleOwnership.allow(
            Sentry.Test.OwnershipServer,
            self(),
            target,
            :sentry_test_scope
          )

        send(parent, {:claimed, self()})

        receive do
          :exit -> :ok
        end
      end)
    end

    test "another live owner cannot steal an allowed pid" do
      target = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> Process.exit(target, :kill) end)

      peer = spawn_peer_owner(target, self())
      on_exit(fn -> Process.exit(peer, :kill) end)
      assert_receive {:claimed, ^peer}, 5000

      assert_raise ArgumentError, ~r/already allowed by another live test scope/, fn ->
        SentryTest.allow_sentry_reports(self(), target)
      end
    end

    test "after the prior owner exits, the same pid can be re-claimed" do
      target = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> Process.exit(target, :kill) end)

      peer = spawn_peer_owner(target, self())
      ref = Process.monitor(peer)
      assert_receive {:claimed, ^peer}, 5000

      send(peer, :exit)
      assert_receive {:DOWN, ^ref, :process, ^peer, _}, 5000

      assert :ok = SentryTest.allow_sentry_reports(self(), target)
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

    setup do
      ctx = SentryTest.setup_sentry(enable_logs: true, logs: [level: :info])

      handler_name = :"sentry_logs_test_#{System.unique_integer([:positive])}"

      handler_config = %{
        config: %{
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
      Logger.info("pop_sentry_logs test message")

      assert_sentry_log(:info, "pop_sentry_logs test message")
    end
  end

  describe "setup_sentry/1 routes buffered events from allowed processes" do
    setup do
      SentryTest.setup_sentry()
      :ok
    end

    test "Sentry.Metrics.count/3 from an allowed pid lands in the test's collector" do
      test_pid = self()
      done = make_ref()

      pid =
        spawn(fn ->
          receive do
            :go ->
              Sentry.Metrics.count("allowance.metric.test", 1)
              send(test_pid, done)
          end
        end)

      ref = Process.monitor(pid)

      assert :ok = SentryTest.allow_sentry_reports(self(), pid)

      send(pid, :go)
      assert_receive ^done, 5_000
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000

      Sentry.TelemetryProcessor.flush()
      Sentry.TelemetryProcessor.flush(Sentry.TelemetryProcessor)

      metrics = SentryTest.pop_sentry_metrics()

      assert Enum.any?(metrics, &(&1.name == "allowance.metric.test")),
             "expected the metric emitted from the allowed pid to land in the " <>
               "test collector, got: #{inspect(metrics)}"
    end
  end

  describe "setup_sentry/1 routes buffered logs from allowed processes" do
    @describetag :capture_log

    setup do
      ctx = SentryTest.setup_sentry(enable_logs: true, logs: [level: :info])

      handler_name = :"sentry_allow_logs_test_#{System.unique_integer([:positive])}"

      handler_config = %{
        config: %{
          enable_logs: true
        }
      }

      :ok = :logger.add_handler(handler_name, Sentry.LoggerHandler, handler_config)

      on_exit(fn ->
        _ = :logger.remove_handler(handler_name)
      end)

      ctx
    end

    test "Logger.warning/1 from an allowed pid lands in the test's collector" do
      test_pid = self()
      done = make_ref()

      pid =
        spawn(fn ->
          receive do
            :go ->
              Logger.warning("hello from allowed pid")
              send(test_pid, done)
          end
        end)

      ref = Process.monitor(pid)

      assert :ok = SentryTest.allow_sentry_reports(self(), pid)

      send(pid, :go)
      assert_receive ^done, 5_000
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000

      Sentry.TelemetryProcessor.flush()
      Sentry.TelemetryProcessor.flush(Sentry.TelemetryProcessor)

      assert_sentry_log(:warn, "hello from allowed pid")
    end
  end
end
