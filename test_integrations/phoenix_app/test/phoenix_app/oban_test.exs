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

    assert transaction.transaction == "Sentry.Integrations.Phoenix.ObanTest.TestWorker"
    assert transaction.transaction_info == %{source: "task"}

    trace = transaction.contexts.trace
    assert trace.origin == "opentelemetry_oban"
    assert trace.op == "queue.process"
    assert trace.data.id
    assert trace.data.queue == "default"
    assert trace.data.retry_count == 1
    assert trace.data.latency > 0

    assert [] = transaction.spans
  end
end
