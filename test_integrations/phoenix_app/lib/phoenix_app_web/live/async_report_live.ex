defmodule PhoenixAppWeb.AsyncReportLive do
  use PhoenixAppWeb, :live_view

  require OpenTelemetry.Tracer, as: Tracer

  @impl true
  def mount(params, _session, socket) do
    start_report_task(params["test_process"])
    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="async-report">Report scheduled</div>
    """
  end

  defp start_report_task(nil), do: :ok

  defp start_report_task(test_process) do
    notify = String.to_existing_atom(test_process)
    ctx = :otel_ctx.get_current()

    {:ok, _pid} =
      Task.start(fn ->
        token = :otel_ctx.attach(ctx)

        try do
          send(notify, {:report_task, self()})

          receive do
            :generate -> :ok
          end

          Tracer.with_span "generate_report" do
            :ok
          end

          send(notify, :report_generated)
        after
          :otel_ctx.detach(token)
        end
      end)

    :ok
  end
end
