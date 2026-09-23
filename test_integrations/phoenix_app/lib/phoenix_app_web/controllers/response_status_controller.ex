defmodule PhoenixAppWeb.ResponseStatusController do
  use PhoenixAppWeb, :controller

  require OpenTelemetry.Tracer, as: Tracer

  alias OpenTelemetry.SemConv.Incubating.HTTPAttributes

  def show(conn, %{"status" => status} = params) do
    start_upstream_call(params["test_process"], params["upstream_status"])

    conn
    |> put_status(String.to_integer(status))
    |> json(%{status: status})
  end

  defp start_upstream_call(nil, _upstream_status), do: :ok

  defp start_upstream_call(test_process, upstream_status) do
    notify = String.to_existing_atom(test_process)
    ctx = :otel_ctx.get_current()

    {:ok, _pid} =
      Task.start(fn ->
        token = :otel_ctx.attach(ctx)

        try do
          Tracer.with_span "GET /upstream", %{
            kind: :client,
            attributes: %{
              HTTPAttributes.http_response_status_code() => String.to_integer(upstream_status)
            }
          } do
            send(notify, {:upstream_call, self()})

            receive do
              :finish_upstream_call -> :ok
            end
          end

          send(notify, :upstream_call_finished)
        after
          :otel_ctx.detach(token)
        end
      end)

    :ok
  end
end
