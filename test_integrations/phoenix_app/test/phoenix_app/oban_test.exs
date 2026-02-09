defmodule Sentry.Integrations.Phoenix.ObanTest do
  use PhoenixAppWeb.ConnCase, async: false
  use Oban.Testing, repo: PhoenixApp.Repo

  import ExUnit.CaptureLog
  import Sentry.TestHelpers

  alias Sentry.Integrations.Oban.ErrorReporter

  setup do
    put_test_config(dsn: "http://public:secret@localhost:8080/1", traces_sample_rate: 1.0)

    Sentry.Test.start_collecting_sentry_reports()

    :ok
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

  test "captures Oban worker execution as transaction" do
    :ok = perform_job(TestWorker, %{test: "args"})

    transactions = Sentry.Test.pop_sentry_transactions()
    assert length(transactions) == 1

    [transaction] = transactions

    assert transaction.transaction == "Sentry.Integrations.Phoenix.ObanTest.TestWorker"
    assert transaction.transaction_info == %{source: :custom}

    trace = transaction.contexts.trace
    assert trace.origin == "opentelemetry_oban"
    assert trace.op == "queue.process"
    assert trace.description == "Sentry.Integrations.Phoenix.ObanTest.TestWorker"
    assert trace.data["oban.job.job_id"]
    assert trace.data["messaging.destination"] == "default"
    assert trace.data["oban.job.attempt"] == 1

    assert [] = transaction.spans
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

      assert [] = Sentry.Test.pop_sentry_reports()
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

      assert [event] = Sentry.Test.pop_sentry_reports()
      assert event.original_exception == %RuntimeError{message: "intentional failure for testing"}

      assert event.tags.oban_worker ==
               "Sentry.Integrations.Phoenix.ObanTest.FailingWorker"
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

      assert [] = Sentry.Test.pop_sentry_reports()
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

      assert [event] = Sentry.Test.pop_sentry_reports()
      assert event.original_exception == %RuntimeError{message: "intentional failure for testing"}
    end

    test "reports error when no callback is configured" do
      ErrorReporter.attach([])

      {:ok, _job} =
        %{"should_fail" => true}
        |> FailingWorker.new()
        |> Oban.insert()

      Oban.drain_queue(queue: :default)

      assert [event] = Sentry.Test.pop_sentry_reports()
      assert event.original_exception == %RuntimeError{message: "intentional failure for testing"}
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

      assert [] = Sentry.Test.pop_sentry_reports()
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

      assert [event] = Sentry.Test.pop_sentry_reports()
      assert event.tags.oban_worker == "NonExistent.Worker.Module"
    end
  end
end
