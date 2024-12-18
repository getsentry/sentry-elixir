defmodule Sentry.Integrations.Phoenix.ObanTest do
  use PhoenixAppWeb.ConnCase, async: false
  use Oban.Testing, repo: PhoenixApp.Repo

  import Sentry.TestHelpers

  setup do
    put_test_config(dsn: "http://public:secret@localhost:8080/1")
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

  test "captures Oban worker execution as transaction" do
    :ok = perform_job(TestWorker, %{test: "args"})

    transactions = Sentry.Test.pop_sentry_transactions()
    assert length(transactions) == 1

    [transaction] = transactions

    assert transaction.transaction == "Sentry.Integrations.Phoenix.ObanTest.TestWorker process"
    assert transaction.transaction_info == %{source: :custom}

    trace = transaction.contexts.trace
    assert trace.origin == "opentelemetry_oban"
    assert trace.op == "Sentry.Integrations.Phoenix.ObanTest.TestWorker process"
    assert trace.data["oban.job.job_id"]
    assert trace.data["messaging.destination"] == "default"
    assert trace.data["oban.job.attempt"] == 1

    assert [_span] = transaction.spans
  end
end
