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

    test ":telemetry_processor option configures the per-test processor" do
      %{telemetry_processor: name} =
        SentryTest.setup_sentry(telemetry_processor: [buffer_configs: %{log: %{batch_size: 1}}])

      log_buffer = Sentry.TelemetryProcessor.get_buffer(name, :log)

      assert :sys.get_state(log_buffer).batch_size == 1
    end

    test ":telemetry_processor option coexists with sibling config options" do
      SentryTest.setup_sentry(
        dedup_events: false,
        telemetry_processor: [buffer_configs: %{log: %{batch_size: 1}}]
      )

      assert Sentry.Config.dedup_events?() == false
    end

    test "re-tags the scheduler after restarting with :telemetry_processor opts" do
      %{telemetry_processor: name} =
        SentryTest.setup_sentry(telemetry_processor: [buffer_configs: %{log: %{batch_size: 1}}])

      scheduler_pid = Sentry.TelemetryProcessor.get_scheduler(name)

      assert is_pid(scheduler_pid)
      assert Sentry.Test.Registry.lookup_processor_for(scheduler_pid) == name
    end

    test "does not return a :ref by default" do
      refute Map.has_key?(SentryTest.setup_sentry(), :ref)
    end

    test "collect_envelopes: true returns a ref that captures sent envelopes" do
      %{ref: ref} = SentryTest.setup_sentry(collect_envelopes: true)

      assert {:ok, _} = Sentry.capture_message("collected", result: :sync)

      assert [[{%{"type" => "event"}, event}]] = SentryTest.collect_envelopes(ref, 1)
      assert event["message"]["formatted"] == "collected"
    end

    test "collect_envelopes accepts collector options forwarded to the collector" do
      %{ref: ref} = SentryTest.setup_sentry(collect_envelopes: [type: "event"])

      assert is_reference(ref)
      assert {:ok, _} = Sentry.capture_message("typed", result: :sync)
      assert [[{%{"type" => "event"}, _}]] = SentryTest.collect_envelopes(ref, 1)
    end

    test "collect_envelopes coexists with :telemetry_processor and config options" do
      %{ref: ref, telemetry_processor: name} =
        SentryTest.setup_sentry(
          dedup_events: false,
          collect_envelopes: true,
          telemetry_processor: [buffer_configs: %{log: %{batch_size: 1}}]
        )

      assert is_reference(ref)
      assert Sentry.Config.dedup_events?() == false

      log_buffer = Sentry.TelemetryProcessor.get_buffer(name, :log)
      assert :sys.get_state(log_buffer).batch_size == 1
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

  describe "setup_sentry/1 with :allowance (foundation)" do
    test "empty allowance list is a no-op" do
      assert %{bypass: _, telemetry_processor: _} =
               SentryTest.setup_sentry(allowance: [])
    end

    test "raises a clear error for unknown allowance entries" do
      assert_raise ArgumentError, ~r/unknown :allowance entry/, fn ->
        SentryTest.setup_sentry(allowance: [SomeUnknownThing])
      end
    end

    test "__attach_allowance__/3 routes worker events back to the owner" do
      SentryTest.setup_sentry()
      test_pid = self()

      SentryTest.__attach_allowance__(
        [:sentry_test_allowance, :synthetic, :start],
        {SentryTest, :__handle_allowance_event__},
        %{owner_pid: test_pid}
      )

      worker_done = make_ref()

      {:ok, _worker} =
        Task.start(fn ->
          :telemetry.execute([:sentry_test_allowance, :synthetic, :start], %{}, %{})

          assert {:ok, _} =
                   Sentry.capture_message("hello from synthetic worker", result: :sync)

          send(test_pid, worker_done)
        end)

      assert_receive ^worker_done, 5_000

      assert [%Sentry.Event{message: %{formatted: "hello from synthetic worker"}}] =
               SentryTest.pop_sentry_reports()
    end
  end

  describe "setup_sentry/1 with allowance: [Oban] (synthetic events)" do
    setup do
      SentryTest.setup_sentry(allowance: [Oban])
    end

    test "tags the job at insert time and routes the worker on start" do
      test_pid = self()
      job = %{id: System.unique_integer([:positive])}

      :telemetry.execute([:oban, :engine, :insert_job, :stop], %{}, %{job: job})
      assert Sentry.Test.Registry.lookup_oban_job(job.id) == test_pid

      worker_done = make_ref()

      # Raw spawn/1 — does NOT propagate $callers, so the worker has no
      # caller-chain link back to the test. The tag store is the only
      # path that can route this worker's events to the test's collector.
      worker =
        spawn(fn ->
          :telemetry.execute([:oban, :job, :start], %{}, %{job: job})

          captured =
            case Sentry.capture_message("oban hello", result: :sync) do
              {:ok, _} -> :captured
              other -> {:unexpected, other}
            end

          send(test_pid, {worker_done, captured})
        end)

      ref = Process.monitor(worker)
      assert_receive {^worker_done, :captured}, 5_000
      assert_receive {:DOWN, ^ref, :process, ^worker, _}, 5_000

      assert [%Sentry.Event{message: %{formatted: "oban hello"}}] =
               SentryTest.pop_sentry_reports()
    end

    test "ignores jobs that were not tagged at insert time" do
      test_pid = self()
      job = %{id: System.unique_integer([:positive])}
      worker_done = make_ref()

      worker =
        spawn(fn ->
          :telemetry.execute([:oban, :job, :start], %{}, %{job: job})

          captured =
            case Sentry.capture_message("untagged", result: :sync) do
              {:ok, _} -> :captured
              other -> {:unexpected, other}
            end

          send(test_pid, {worker_done, captured})
        end)

      ref = Process.monitor(worker)
      assert_receive {^worker_done, :captured}, 5_000
      assert_receive {:DOWN, ^ref, :process, ^worker, _}, 5_000

      assert [] == SentryTest.pop_sentry_reports()
    end

    test "untags the job on :stop" do
      job = %{id: System.unique_integer([:positive])}
      :telemetry.execute([:oban, :engine, :insert_job, :stop], %{}, %{job: job})
      assert Sentry.Test.Registry.lookup_oban_job(job.id) == self()

      :telemetry.execute([:oban, :job, :stop], %{}, %{job: job})
      refute Sentry.Test.Registry.lookup_oban_job(job.id)
    end

    test "untags the job on :exception" do
      job = %{id: System.unique_integer([:positive])}
      :telemetry.execute([:oban, :engine, :insert_job, :stop], %{}, %{job: job})
      assert Sentry.Test.Registry.lookup_oban_job(job.id) == self()

      :telemetry.execute([:oban, :job, :exception], %{}, %{job: job})
      refute Sentry.Test.Registry.lookup_oban_job(job.id)
    end

    test "insert_all_jobs tags every job in the batch" do
      jobs = [
        %{id: System.unique_integer([:positive])},
        %{id: System.unique_integer([:positive])}
      ]

      :telemetry.execute([:oban, :engine, :insert_all_jobs, :stop], %{}, %{jobs: jobs})

      for job <- jobs do
        assert Sentry.Test.Registry.lookup_oban_job(job.id) == self()
      end
    end

    test "silently ignores synthetic jobs without an integer id" do
      # :inline mode jobs / ad-hoc telemetry simulations may carry no id.
      :telemetry.execute([:oban, :engine, :insert_job, :stop], %{}, %{job: %{id: nil}})
      :telemetry.execute([:oban, :job, :start], %{}, %{job: %{id: nil}})
      :ok
    end

    test "two concurrent test scopes are routed independently" do
      test_pid = self()
      job_for_me = %{id: System.unique_integer([:positive])}
      job_for_peer = %{id: System.unique_integer([:positive])}

      # Spawn a peer that acts as a separate live owner via NimbleOwnership,
      # tags its own Oban job, and reports back when ready.
      peer =
        spawn(fn ->
          {:ok, _} =
            NimbleOwnership.get_and_update(
              Sentry.Test.OwnershipServer,
              self(),
              :sentry_test_collector,
              fn _ -> {:ok, :peer_table} end
            )

          Sentry.Test.Registry.tag_oban_job(job_for_peer.id, self())
          send(test_pid, :claimed)

          receive do
            :exit -> :ok
          end
        end)

      on_exit(fn -> Process.exit(peer, :kill) end)
      assert_receive :claimed, 5_000

      # Tag my own job.
      :telemetry.execute([:oban, :engine, :insert_job, :stop], %{}, %{job: job_for_me})

      assert Sentry.Test.Registry.lookup_oban_job(job_for_me.id) == test_pid
      assert Sentry.Test.Registry.lookup_oban_job(job_for_peer.id) == peer
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
