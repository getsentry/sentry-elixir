defmodule PhoenixAppWeb.AsyncTraceController do
  @moduledoc """
  Scenarios where spans outlive the HTTP request that started them.

  Exercised by the tracing e2e suite, and useful for manually verifying
  reported traces in the Sentry UI: run the server with a real `SENTRY_DSN`
  and click through `/async-traces`.
  """

  use PhoenixAppWeb, :controller

  require OpenTelemetry.Tracer, as: Tracer

  alias PhoenixApp.Repo

  @task_work_ms 500

  def index(conn, _params) do
    html(conn, """
    <html>
      <head><title>Async trace scenarios</title></head>
      <body>
        <h1>Async trace scenarios</h1>
        <ul>
          <li><a id="in-flight" href="/async-traces/in-flight">In-flight report delivery</a></li>
          <li><a id="nested" href="/async-traces/nested">Nested batch finalization</a></li>
        </ul>
      </body>
    </html>
    """)
  end

  def in_flight(conn, _params) do
    caller = self()
    ctx = :otel_ctx.get_current()

    {:ok, _pid} =
      Task.start(fn ->
        token = :otel_ctx.attach(ctx)

        try do
          Tracer.with_span "deliver_report" do
            send(caller, :report_started)
            Process.sleep(@task_work_ms)
          end
        after
          :otel_ctx.detach(token)
        end
      end)

    receive do
      :report_started -> :ok
    after
      1_000 -> :ok
    end

    json(conn, %{status: "report delivery in progress"})
  end

  def nested(conn, _params) do
    Tracer.with_span "process_batch" do
      Repo.query!("SELECT 1")
      ctx = :otel_ctx.get_current()

      {:ok, _pid} =
        Task.start(fn ->
          token = :otel_ctx.attach(ctx)

          try do
            Process.sleep(@task_work_ms)

            Tracer.with_span "finalize_batch" do
              Process.sleep(10)
            end
          after
            :otel_ctx.detach(token)
          end
        end)
    end

    json(conn, %{status: "batch scheduled"})
  end
end
