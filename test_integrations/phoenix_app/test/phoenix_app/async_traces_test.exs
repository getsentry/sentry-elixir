defmodule PhoenixApp.AsyncTracesTest do
  use PhoenixAppWeb.ConnCase, async: false
  use Oban.Testing, repo: PhoenixApp.Repo

  import Sentry.Test.Assertions
  import Sentry.TestHelpers

  setup do
    Sentry.Test.setup_sentry(collect_envelopes: true, traces_sample_rate: 1.0)
  end

  defmodule ReportWorker do
    use Oban.Worker

    require OpenTelemetry.Tracer, as: Tracer

    @impl Oban.Worker
    def perform(%Oban.Job{}) do
      runner = self()
      ctx = :otel_ctx.get_current()

      task =
        Task.async(fn ->
          token = :otel_ctx.attach(ctx)

          try do
            Tracer.with_span "deliver_report" do
              send(runner, :report_started)

              receive do
                :deliver -> :ok
              end
            end
          after
            :otel_ctx.detach(token)
          end
        end)

      receive do
        :report_started -> :ok
      end

      {:ok, task}
    end
  end

  defmodule BatchWorker do
    use Oban.Worker

    require OpenTelemetry.Tracer, as: Tracer

    @impl Oban.Worker
    def perform(%Oban.Job{}) do
      task =
        Tracer.with_span "process_batch" do
          PhoenixApp.Repo.query!("SELECT 1")
          ctx = :otel_ctx.get_current()

          Task.async(fn ->
            token = :otel_ctx.attach(ctx)

            try do
              receive do
                :finalize -> :ok
              end

              Tracer.with_span "finalize_batch" do
                :ok
              end
            after
              :otel_ctx.detach(token)
            end
          end)
        end

      {:ok, task}
    end
  end

  test "an Oban job transaction excludes spans that are still in flight", %{ref: ref} do
    {:ok, task} = perform_job(ReportWorker, %{})

    job_tx =
      find_sentry_report!(
        collect_sentry_transactions(ref, 100, timeout: 500),
        transaction: "#{inspect(ReportWorker)}"
      )

    assert job_tx["contexts"]["trace"]["origin"] == "opentelemetry_oban"

    assert Enum.all?(job_tx["spans"], & &1["timestamp"]),
           "job transaction contains spans without an end timestamp"

    send(task.pid, :deliver)
    Task.await(task)
  end

  test "work outliving an Oban job is reported as a follow-up transaction", %{ref: ref} do
    {:ok, task} = perform_job(ReportWorker, %{})

    job_tx =
      find_sentry_report!(
        collect_sentry_transactions(ref, 100, timeout: 500),
        transaction: "#{inspect(ReportWorker)}"
      )

    send(task.pid, :deliver)
    Task.await(task)

    report_tx =
      find_sentry_report!(
        collect_sentry_transactions(ref, 100, timeout: 500),
        transaction: "deliver_report"
      )

    job_trace = job_tx["contexts"]["trace"]
    report_trace = report_tx["contexts"]["trace"]

    assert report_trace["trace_id"] == job_trace["trace_id"]
    assert report_trace["parent_span_id"] == job_trace["span_id"]
    assert report_trace["data"]["sentry.parent_span_already_sent"] == true
  end

  test "late work continuing from a nested span of an Oban job is reported", %{ref: ref} do
    {:ok, task} = perform_job(BatchWorker, %{})

    job_tx =
      find_sentry_report!(
        collect_sentry_transactions(ref, 100, timeout: 500),
        transaction: "#{inspect(BatchWorker)}"
      )

    batch_span = Enum.find(job_tx["spans"], &(&1["description"] == "process_batch"))
    db_span = Enum.find(job_tx["spans"], &(&1["op"] == "db"))

    assert batch_span
    assert db_span["parent_span_id"] == batch_span["span_id"]

    send(task.pid, :finalize)
    Task.await(task)

    finalize_tx =
      find_sentry_report!(
        collect_sentry_transactions(ref, 100, timeout: 500),
        transaction: "finalize_batch"
      )

    finalize_trace = finalize_tx["contexts"]["trace"]

    assert finalize_trace["trace_id"] == job_tx["contexts"]["trace"]["trace_id"]
    assert finalize_trace["parent_span_id"] == batch_span["span_id"]
    assert finalize_trace["data"]["sentry.parent_span_already_sent"] == true
  end

  test "async work started in a LiveView mount is reported after the mount transaction", %{
    conn: conn,
    ref: ref
  } do
    name = :"async_report_test_#{System.unique_integer([:positive])}"
    Process.register(self(), name)

    get(conn, ~p"/async-report?test_process=#{name}")

    mount_tx =
      find_sentry_report!(
        collect_sentry_transactions(ref, 100, timeout: 500),
        transaction: "PhoenixAppWeb.AsyncReportLive.mount"
      )

    assert mount_tx["contexts"]["trace"]["origin"] == "opentelemetry_phoenix"

    assert_receive {:report_task, task_pid}
    send(task_pid, :generate)
    assert_receive :report_generated, 1000

    report_tx =
      find_sentry_report!(
        collect_sentry_transactions(ref, 100, timeout: 500),
        transaction: "generate_report"
      )

    mount_trace = mount_tx["contexts"]["trace"]
    report_trace = report_tx["contexts"]["trace"]

    assert report_trace["trace_id"] == mount_trace["trace_id"]
    assert report_trace["parent_span_id"] == mount_trace["span_id"]
    assert report_trace["data"]["sentry.parent_span_already_sent"] == true
  end
end
