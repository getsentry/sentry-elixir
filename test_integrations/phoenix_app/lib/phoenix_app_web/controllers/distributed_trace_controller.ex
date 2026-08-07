defmodule PhoenixAppWeb.DistributedTraceController do
  @moduledoc """
  Scenarios where this node continues a trace started by an upstream service.

  The handoff scenario mirrors work dispatched to a background worker or a
  separate runner node: the upstream W3C context is carried along and the
  spans are created after the request that delivered it has already finished,
  so their parent belongs to another process entirely.

  Exercised by the tracing e2e suite, and useful for manually verifying
  reported traces in the Sentry UI: run the server with a real `SENTRY_DSN`
  and click through `/distributed-traces`.
  """

  use PhoenixAppWeb, :controller

  require OpenTelemetry.Tracer, as: Tracer

  alias PhoenixApp.Repo

  @handoff_delay_ms 400

  def index(conn, _params) do
    html(conn, """
    <html>
      <head><title>Distributed trace scenarios</title></head>
      <body>
        <h1>Distributed trace scenarios</h1>
        <ul>
          <li><a id="handoff" href="#">Upstream handoff to a background sync</a></li>
        </ul>
        <pre id="result"></pre>
        <script>
          function hex(length) {
            const bytes = new Uint8Array(length / 2);
            crypto.getRandomValues(bytes);
            return Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
          }

          document.getElementById("handoff").addEventListener("click", async (event) => {
            event.preventDefault();

            const traceparent = "00-" + hex(32) + "-" + hex(16) + "-01";
            const response = await fetch("/distributed-traces/handoff", {
              headers: { traceparent: traceparent },
            });

            document.getElementById("result").textContent =
              "upstream: " + traceparent + "\\n" + JSON.stringify(await response.json());
          });
        </script>
      </body>
    </html>
    """)
  end

  def handoff(conn, _params) do
    case upstream_traceparent(conn) do
      nil ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "no traceparent or sentry-trace header"})

      traceparent ->
        start_background_sync(traceparent)
        json(conn, %{status: "sync scheduled", upstream: traceparent})
    end
  end

  defp start_background_sync(traceparent) do
    {:ok, _pid} =
      Task.start(fn ->
        Process.sleep(@handoff_delay_ms)

        :otel_propagator_text_map.extract([{"traceparent", traceparent}])

        Tracer.with_span "sync.run" do
          Repo.query!("SELECT 1")
        end
      end)

    :ok
  end

  defp upstream_traceparent(conn) do
    case get_req_header(conn, "traceparent") do
      [traceparent | _] -> traceparent
      [] -> conn |> get_req_header("sentry-trace") |> from_sentry_trace()
    end
  end

  defp from_sentry_trace([sentry_trace | _]) do
    case String.split(sentry_trace, "-") do
      [trace_id, span_id | rest] ->
        flags = if rest == ["0"], do: "00", else: "01"
        "00-#{trace_id}-#{span_id}-#{flags}"

      _ ->
        nil
    end
  end

  defp from_sentry_trace(_), do: nil
end
