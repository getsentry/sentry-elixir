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
end
