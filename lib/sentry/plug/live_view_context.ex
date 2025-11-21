if Code.ensure_loaded?(Plug) and Sentry.OpenTelemetry.VersionChecker.tracing_compatible?() do
  defmodule Sentry.Plug.LiveViewContext do
    @moduledoc """
    Plug that captures the current OpenTelemetry context and embeds it into the LiveView session.

    When placed before your LiveView routes, it serializes the currently attached trace (`sentry-trace`
    and `baggage`) via `Sentry.OpenTelemetry.Propagator`. The serialized carrier is stored under
    `"__sentry_live_view_context__"` in the session so the LiveView process can pick it up, and a
    companion cleanup plug removes the key after the response has been committed.
    """

    @behaviour Plug

    alias OpenTelemetry.Ctx
    alias OpenTelemetry.Tracer
    alias Sentry.OpenTelemetry.Propagator

    @session_key "__sentry_live_view_context__"
    @sentry_trace_header "sentry-trace"
    @ctx_token_key :sentry_live_view_ctx_token

    @impl Plug
    def init(opts), do: opts

    @impl Plug
    def call(conn, _opts) do
      {conn, carrier} = ensure_trace_carrier(conn)
      store_session(conn, carrier)
    end

    defp store_session(conn, carrier) do
      if Map.has_key?(carrier, @sentry_trace_header) do
        conn
        |> Plug.Conn.fetch_session()
        |> Plug.Conn.put_session(@session_key, carrier)
      else
        conn
      end
    end

    defp ensure_trace_carrier(conn) do
      ctx_carrier = build_carrier_from_ctx()

      if Map.has_key?(ctx_carrier, @sentry_trace_header) do
        {conn, ctx_carrier}
      else
        header_carrier = build_carrier_from_headers(conn)

        if Map.has_key?(header_carrier, @sentry_trace_header) do
          attach_conn = attach_from_headers(conn, header_carrier)
          {attach_conn, header_carrier}
        else
          {conn, header_carrier}
        end
      end
    end

    defp build_carrier_from_ctx do
      ctx = Ctx.get_current()
      setter = fn key, value, acc -> Map.put(acc, key, value) end
      Propagator.inject(ctx, %{}, setter, [])
    end

    defp build_carrier_from_headers(conn) do
      Enum.reduce([@sentry_trace_header, "baggage"], %{}, fn header, acc ->
        case Plug.Conn.get_req_header(conn, header) do
          [value | _] -> Map.put(acc, header, value)
          _ -> acc
        end
      end)
    end

    defp attach_from_headers(conn, carrier) do
      ctx = maybe_extract(carrier)

      case ctx do
        nil ->
          conn

        _ ->
          span_ctx = Tracer.current_span_ctx(ctx)

          if span_ctx == :undefined do
            conn
          else
            token = Ctx.attach(ctx)
            register_detach(conn, token)
          end
      end
    end

    defp maybe_extract(carrier) do
      ctx = Ctx.get_current()
      getter = fn key, _ -> Map.get(carrier, key, :undefined) end
      Propagator.extract(ctx, carrier, fn _ -> Map.keys(carrier) end, getter, [])
    rescue
      _ -> nil
    end

    defp register_detach(conn, token) do
      conn
      |> Plug.Conn.put_private(@ctx_token_key, token)
      |> Plug.Conn.register_before_send(fn conn ->
        _ =
          case conn.private[@ctx_token_key] do
            nil -> :ok
            token -> Ctx.detach(token)
          end

        conn
      end)
    end

    @doc false
    def delete_session_key(conn) do
      Plug.Conn.delete_session(conn, @session_key)
    end
  end
end
