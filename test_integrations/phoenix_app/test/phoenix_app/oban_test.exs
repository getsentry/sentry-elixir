defmodule Sentry.Integrations.Phoenix.ObanTest do
  use PhoenixAppWeb.ConnCase, async: false
  use Oban.Testing, repo: PhoenixApp.Repo

  import ExUnit.CaptureLog
  import Sentry.Test.Assertions
  import Sentry.TestHelpers

  require OpenTelemetry.Tracer

  alias Sentry.Integrations.Oban.ErrorReporter

  setup do
    Sentry.Test.setup_sentry(collect_envelopes: true, traces_sample_rate: 1.0)
  end

  defmodule TestWorker do
    use Oban.Worker

    @impl Oban.Worker
    def perform(_args) do
      :timer.sleep(100)
    end
  end

  defmodule FailingWorker do
    use Oban.Worker, max_attempts: 3

    @impl Oban.Worker
    def perform(%Oban.Job{args: %{"should_fail" => true}}) do
      raise "intentional failure for testing"
    end

    def perform(_job), do: :ok
  end

  defmodule WorkerWithDatabaseQuery do
    use Oban.Worker

    @impl Oban.Worker
    def perform(%Oban.Job{}) do
      # Execute a database query to generate child spans
      PhoenixApp.Repo.query("SELECT 1")
      :ok
    end
  end

  test "captures Oban worker execution as transaction" do
    :ok = perform_job(TestWorker, %{test: "args"})

    tx =
      assert_sentry_report(:transaction,
        transaction: "Sentry.Integrations.Phoenix.ObanTest.TestWorker",
        transaction_info: %{source: :custom}
      )

    trace = tx.contexts.trace
    assert trace.origin == "opentelemetry_oban"
    assert trace.op == "queue.process"
    assert trace.description == "Sentry.Integrations.Phoenix.ObanTest.TestWorker"
    assert trace.data["oban.job.job_id"]
    assert trace.data["messaging.destination.name"] == "default"
    assert trace.data["oban.job.attempt"] == 1

    assert tx.spans == []
  end

  test "captures Oban worker with trace links", %{ref: ref} do
    # This test verifies that when an Oban job is inserted within an active trace,
    # the consumer span has links back to the producer span.

    # Insert within an active span so trace context is propagated into job metadata
    OpenTelemetry.Tracer.with_span "test.request" do
      {:ok, _job} =
        %{test: "with_links"}
        |> TestWorker.new()
        |> OpentelemetryOban.insert()
    end

    # Drain the queue to execute the job
    Oban.drain_queue(queue: :default)

    transactions = collect_sentry_transactions(ref, 100, timeout: 500)

    oban_tx =
      find_sentry_report!(transactions, contexts: %{trace: %{origin: "opentelemetry_oban"}})

    trace = oban_tx["contexts"]["trace"]
    assert trace["op"] == "queue.process"
    assert trace["origin"] == "opentelemetry_oban"

    # Verify span links are present and properly formatted
    assert is_list(trace["links"]), "expected trace links to be present"
    assert length(trace["links"]) > 0, "expected at least one span link"

    for link <- trace["links"] do
      assert is_binary(link["span_id"])
      assert is_binary(link["trace_id"])
      assert String.match?(link["span_id"], ~r/^[a-f0-9]{16}$/)
      assert String.match?(link["trace_id"], ~r/^[a-f0-9]{32}$/)
    end
  end

  test "captures Oban worker with child spans" do
    :ok = perform_job(WorkerWithDatabaseQuery, %{})

    tx =
      assert_sentry_report(:transaction,
        transaction: "Sentry.Integrations.Phoenix.ObanTest.WorkerWithDatabaseQuery"
      )

    assert length(tx.spans) > 0

    assert Enum.any?(tx.spans, fn span -> span.op == "db" end)
  end

  describe "should_report_error_callback config" do
    setup do
      :telemetry.detach(ErrorReporter)

      on_exit(fn ->
        _ = :telemetry.detach(ErrorReporter)
        ErrorReporter.attach([])
      end)

      :ok
    end

    test "skips error reporting when callback returns false" do
      test_pid = self()

      ErrorReporter.attach(
        should_report_error_callback: fn worker, job ->
          send(test_pid, {:callback_invoked, worker, job})
          false
        end
      )

      {:ok, _job} =
        %{"should_fail" => true}
        |> FailingWorker.new()
        |> Oban.insert()

      assert %{failure: 1} = Oban.drain_queue(queue: :default)

      assert_receive {:callback_invoked, worker, received_job}
      assert worker == FailingWorker
      assert %Oban.Job{} = received_job
      assert received_job.args == %{"should_fail" => true}

      assert [] == Sentry.Test.pop_sentry_reports()
    end

    test "reports error when callback returns true" do
      test_pid = self()

      ErrorReporter.attach(
        should_report_error_callback: fn worker, job ->
          send(test_pid, {:callback_invoked, worker, job})
          true
        end
      )

      {:ok, _job} =
        %{"should_fail" => true}
        |> FailingWorker.new()
        |> Oban.insert()

      assert %{failure: 1} = Oban.drain_queue(queue: :default)

      assert_receive {:callback_invoked, _worker, _job}

      event =
        find_sentry_report!(Sentry.Test.pop_sentry_reports(),
          tags: %{oban_worker: "Sentry.Integrations.Phoenix.ObanTest.FailingWorker"}
        )

      assert [
               %Sentry.Interfaces.Exception{
                 type: "RuntimeError",
                 value: "intentional failure for testing"
               }
               | _
             ] =
               event.exception
    end

    test "callback receives worker module and full job struct" do
      test_pid = self()

      ErrorReporter.attach(
        should_report_error_callback: fn worker, job ->
          send(test_pid, {:callback_args, worker, job})
          true
        end
      )

      {:ok, _job} =
        %{"should_fail" => true, "user_id" => 123}
        |> FailingWorker.new()
        |> Oban.insert()

      Oban.drain_queue(queue: :default)

      assert_receive {:callback_args, worker, job}

      assert worker == FailingWorker
      assert is_atom(worker)

      assert %Oban.Job{} = job
      assert job.args == %{"should_fail" => true, "user_id" => 123}
      assert job.worker == "Sentry.Integrations.Phoenix.ObanTest.FailingWorker"
      assert job.queue == "default"
      assert job.max_attempts == 3
      assert is_integer(job.attempt)
      assert is_integer(job.id)
    end

    test "callback can make decisions based on attempt number" do
      test_pid = self()

      ErrorReporter.attach(
        should_report_error_callback: fn _worker, job ->
          should_report = job.attempt >= job.max_attempts
          send(test_pid, {:report_decision, job.attempt, job.max_attempts, should_report})
          should_report
        end
      )

      {:ok, _job} =
        %{"should_fail" => true}
        |> FailingWorker.new()
        |> Oban.insert()

      Oban.drain_queue(queue: :default)

      assert_receive {:report_decision, attempt, max_attempts, should_report}
      assert attempt == 1
      assert max_attempts == 3
      assert should_report == false

      assert [] == Sentry.Test.pop_sentry_reports()
    end

    test "handles callback errors gracefully and defaults to reporting" do
      log =
        capture_log(fn ->
          ErrorReporter.attach(
            should_report_error_callback: fn _worker, _job ->
              raise "callback crashed!"
            end
          )

          {:ok, _job} =
            %{"should_fail" => true}
            |> FailingWorker.new()
            |> Oban.insert()

          Oban.drain_queue(queue: :default)
        end)

      assert log =~ "should_report_error_callback failed"
      assert log =~ "FailingWorker"
      assert log =~ "callback crashed!"

      event =
        find_sentry_report!(Sentry.Test.pop_sentry_reports(),
          tags: %{oban_worker: "Sentry.Integrations.Phoenix.ObanTest.FailingWorker"}
        )

      assert [
               %Sentry.Interfaces.Exception{
                 type: "RuntimeError",
                 value: "intentional failure for testing"
               }
               | _
             ] =
               event.exception
    end

    test "reports error when no callback is configured" do
      ErrorReporter.attach([])

      {:ok, _job} =
        %{"should_fail" => true}
        |> FailingWorker.new()
        |> Oban.insert()

      Oban.drain_queue(queue: :default)

      event =
        find_sentry_report!(Sentry.Test.pop_sentry_reports(),
          tags: %{oban_worker: "Sentry.Integrations.Phoenix.ObanTest.FailingWorker"}
        )

      assert [
               %Sentry.Interfaces.Exception{
                 type: "RuntimeError",
                 value: "intentional failure for testing"
               }
               | _
             ] =
               event.exception
    end

    test "callback can filter based on worker type" do
      test_pid = self()

      ErrorReporter.attach(
        should_report_error_callback: fn worker, _job ->
          should_report = worker != FailingWorker
          send(test_pid, {:worker_check, worker, should_report})
          should_report
        end
      )

      {:ok, _job} =
        %{"should_fail" => true}
        |> FailingWorker.new()
        |> Oban.insert()

      Oban.drain_queue(queue: :default)

      assert_receive {:worker_check, FailingWorker, false}

      assert [] == Sentry.Test.pop_sentry_reports()
    end

    test "callback receives nil and logs warning for non-existent worker module" do
      test_pid = self()

      log =
        capture_log(fn ->
          ErrorReporter.attach(
            should_report_error_callback: fn worker, job ->
              send(test_pid, {:callback_with_unknown_worker, worker, job})
              true
            end
          )

          job = %Oban.Job{
            id: 999,
            args: %{"test" => true},
            worker: "NonExistent.Worker.Module",
            queue: "default",
            state: "executing",
            attempt: 1,
            max_attempts: 3
          }

          :telemetry.execute(
            [:oban, :job, :exception],
            %{duration: 1000},
            %{
              job: job,
              kind: :error,
              reason: %RuntimeError{message: "worker failed"},
              stacktrace: []
            }
          )
        end)

      assert log =~ "Could not resolve Oban worker module from string"
      assert log =~ "NonExistent.Worker.Module"

      assert_receive {:callback_with_unknown_worker, worker, received_job}
      assert worker == nil
      assert received_job.worker == "NonExistent.Worker.Module"

      event =
        assert_sentry_report(:event,
          tags: %{oban_worker: "NonExistent.Worker.Module"}
        )

      assert event.tags[:oban_worker] == "NonExistent.Worker.Module"
    end
  end

  describe "allow_sentry_reports/2 with a real Oban worker process" do
    setup do
      Sentry.Test.setup_sentry()
      Sentry.Integrations.Oban.ErrorReporter.attach()
      on_exit(fn -> :telemetry.detach(Sentry.Integrations.Oban.ErrorReporter) end)
    end

    test "events from the worker process are dropped without an explicit allow" do
      run_failing_worker_in_detached_process(before_perform: fn -> :ok end)

      assert [] == Sentry.Test.pop_sentry_reports()
    end

    test "events from the worker process are captured when allowed via a telemetry hook" do
      test_pid = self()
      handler_id = {:sentry_allow_test, System.unique_integer([:positive])}

      try do
        :telemetry.attach(
          handler_id,
          [:oban, :job, :start],
          fn _event, _measurements, _metadata, _config ->
            Sentry.Test.allow_sentry_reports(test_pid, self())
          end,
          nil
        )

        run_failing_worker_in_detached_process(before_perform: fn -> :ok end)
      after
        :telemetry.detach(handler_id)
      end

      assert [%Sentry.Event{} = event] = Sentry.Test.pop_sentry_reports()

      assert [exception] = event.exception
      assert exception.type == "RuntimeError"
      assert exception.value == "intentional failure for testing"

      assert event.tags[:oban_worker] ==
               "Sentry.Integrations.Phoenix.ObanTest.FailingWorker"
    end
  end

  describe "setup_sentry/1 with allowance: [Oban]" do
    setup do
      Sentry.Test.setup_sentry(allowance: [Oban])
      Sentry.Integrations.Oban.ErrorReporter.attach()
      on_exit(fn -> :telemetry.detach(Sentry.Integrations.Oban.ErrorReporter) end)
    end

    test "captures events from a real Oban worker with no manual telemetry plumbing" do
      job = %Oban.Job{
        id: System.unique_integer([:positive]),
        args: %{"should_fail" => true},
        worker: "Sentry.Integrations.Phoenix.ObanTest.FailingWorker",
        queue: "background",
        attempt: 1,
        max_attempts: 1,
        meta: %{},
        inserted_at: DateTime.utc_now(),
        scheduled_at: DateTime.utc_now(),
        attempted_at: DateTime.utc_now()
      }

      # Phase 1: simulate the insert-time engine event in the test pid.
      # The allowance handler tags this job's id with self() so the
      # detached worker can be routed back here on :start.
      :telemetry.execute(
        [:oban, :engine, :insert_job, :stop],
        %{},
        %{job: job, conf: %{name: Oban}}
      )

      assert Sentry.Test.Registry.lookup_oban_job(job.id) == self()

      # Phase 2: run the worker in a detached process — no `$callers`
      # link to this test, so the only path that can route the worker's
      # captured events back is the tag established above.
      run_job_in_detached_process(job)

      # The FailingWorker raises; the Oban error reporter turns it into
      # an event, and the allowance routing delivers it to this test.
      assert [%Sentry.Event{} = event] = Sentry.Test.pop_sentry_reports()

      assert [%Sentry.Interfaces.Exception{} = exception] = event.exception
      assert exception.value == "intentional failure for testing"
    end

    test "captures Sentry.Metrics.count/3 from a real Oban worker" do
      job = %Oban.Job{
        id: System.unique_integer([:positive]),
        args: %{},
        worker: "Sentry.Integrations.Phoenix.ObanTest.FailingWorker",
        queue: "background",
        attempt: 1,
        max_attempts: 1,
        meta: %{},
        inserted_at: DateTime.utc_now(),
        scheduled_at: DateTime.utc_now(),
        attempted_at: DateTime.utc_now()
      }

      :telemetry.execute(
        [:oban, :engine, :insert_job, :stop],
        %{},
        %{job: job, conf: %{name: Oban}}
      )

      assert Sentry.Test.Registry.lookup_oban_job(job.id) == self()

      emit_metric_in_detached_process(job, fn ->
        Sentry.Metrics.count("oban.allowance.metric.test", 1)
      end)

      Sentry.TelemetryProcessor.flush()
      Sentry.TelemetryProcessor.flush(Sentry.TelemetryProcessor)

      metrics = Sentry.Test.pop_sentry_metrics()

      assert Enum.any?(metrics, &(&1.name == "oban.allowance.metric.test")),
             "expected metric emitted from the Oban worker process to land in the " <>
               "test collector, got: #{inspect(metrics)}"
    end
  end

  defp run_job_in_detached_process(job) do
    parent = self()
    ref = make_ref()

    spawn(fn ->
      start_metadata = %{job: job, conf: %{name: Oban}}

      :telemetry.execute(
        [:oban, :job, :start],
        %{system_time: System.system_time()},
        start_metadata
      )

      {kind, reason, stacktrace} =
        try do
          FailingWorker.perform(job)
          {:ok, nil, []}
        catch
          kind, reason -> {kind, reason, __STACKTRACE__}
        end

      :telemetry.execute(
        [:oban, :job, :exception],
        %{duration: 0},
        Map.merge(start_metadata, %{
          kind: kind,
          reason: reason,
          error: reason,
          stacktrace: stacktrace,
          state: :failure
        })
      )

      send(parent, {ref, :done})
    end)

    receive do
      {^ref, :done} -> :ok
    after
      5_000 -> flunk("worker process did not finish in time")
    end

    Process.sleep(50)
  end

  defp run_failing_worker_in_detached_process(opts) do
    parent = self()
    ref = make_ref()

    spawn(fn ->
      Keyword.fetch!(opts, :before_perform).()

      job = %Oban.Job{
        id: System.unique_integer([:positive]),
        args: %{"should_fail" => true},
        worker: "Sentry.Integrations.Phoenix.ObanTest.FailingWorker",
        queue: "background",
        attempt: 1,
        max_attempts: 1,
        meta: %{},
        inserted_at: DateTime.utc_now(),
        scheduled_at: DateTime.utc_now(),
        attempted_at: DateTime.utc_now()
      }

      start_metadata = %{job: job, conf: %{name: Oban}}

      :telemetry.execute(
        [:oban, :job, :start],
        %{system_time: System.system_time()},
        start_metadata
      )

      {kind, reason, stacktrace} =
        try do
          FailingWorker.perform(job)
          {:ok, nil, []}
        catch
          kind, reason -> {kind, reason, __STACKTRACE__}
        end

      exception_metadata =
        Map.merge(start_metadata, %{
          kind: kind,
          reason: reason,
          error: reason,
          stacktrace: stacktrace,
          state: :failure
        })

      :telemetry.execute(
        [:oban, :job, :exception],
        %{duration: 0},
        exception_metadata
      )

      send(parent, {ref, :done})
    end)

    receive do
      {^ref, :done} -> :ok
    after
      5_000 -> flunk("worker process did not finish in time")
    end

    Process.sleep(50)
  end

  defp emit_metric_in_detached_process(job, fun) do
    parent = self()
    ref = make_ref()

    spawn(fn ->
      start_metadata = %{job: job, conf: %{name: Oban}}

      :telemetry.execute(
        [:oban, :job, :start],
        %{system_time: System.system_time()},
        start_metadata
      )

      fun.()

      :telemetry.execute(
        [:oban, :job, :stop],
        %{duration: 0},
        Map.merge(start_metadata, %{state: :success, result: :ok})
      )

      send(parent, {ref, :done})
    end)

    receive do
      {^ref, :done} -> :ok
    after
      5_000 -> flunk("worker process did not finish in time")
    end

    Process.sleep(50)
  end
end
