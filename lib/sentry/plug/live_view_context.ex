if Sentry.OpenTelemetry.VersionChecker.tracing_compatible?() and
     Code.ensure_loaded?(Phoenix.LiveView) do
  defmodule Sentry.Plug.LiveViewContext do
    @moduledoc """
    A Plug that stores OpenTelemetry context in the session for LiveView distributed tracing.

    This plug serializes the current OpenTelemetry context into the session, allowing
    LiveView processes to restore the trace context and maintain distributed tracing
    continuity.

    ## Why This Is Needed

    When a browser requests a page with a LiveView, the HTTP request comes with distributed
    tracing headers (e.g., `sentry-trace`, `traceparent`). OpenTelemetry propagators extract
    these headers and attach the trace context to the request process.

    However, Phoenix LiveView creates fresh BEAM processes for each lifecycle callback
    (mount, handle_params, etc.). These new processes don't automatically inherit the
    OpenTelemetry context from the HTTP request process, causing trace continuity to break.

    This plug bridges that gap by:
    1. Serializing the current trace context into the session before LiveView renders
    2. Allowing `Sentry.OpenTelemetry.LiveViewPropagator` to restore the context in LiveView processes

    ## Usage

    ### Step 1: Set up telemetry handlers

    In your application's `start/2` callback, call `Sentry.OpenTelemetry.LiveViewPropagator.setup/0`
    **BEFORE** `OpentelemetryPhoenix.setup/1`:

        def start(_type, _args) do
          # Set up Sentry's LiveView context propagation FIRST
          Sentry.OpenTelemetry.LiveViewPropagator.setup()

          # Then set up OpentelemetryPhoenix
          OpentelemetryPhoenix.setup(adapter: :bandit)

          children = [
            # ...
          ]

          Supervisor.start_link(children, strategy: :one_for_one)
        end

    ### Step 2: Add this plug to your router

    Add this plug to your router pipeline that serves LiveViews, **after** the session
    plug and **before** LiveView routes:

        pipeline :browser do
          plug :accepts, ["html"]
          plug :fetch_session
          plug :fetch_live_flash
          plug :put_root_layout, html: {MyAppWeb.Layouts, :root}
          plug :protect_from_forgery
          plug :put_secure_browser_headers
          plug Sentry.Plug.LiveViewContext  # Add this line
        end

    ## How It Works

    1. This plug serializes the current trace context into the session during the HTTP
       request phase (static LiveView render).

    2. `Sentry.OpenTelemetry.LiveViewPropagator` attaches telemetry handlers that run
       BEFORE `opentelemetry_phoenix` creates spans.

    3. When LiveView lifecycle events fire (mount, handle_params, handle_event), the
       propagator extracts the trace context from the session and attaches it to the
       process before `opentelemetry_phoenix` creates its spans.

    4. All subsequent OpenTelemetry spans created in the LiveView process will now
       share the same trace ID as the original HTTP request.

    ## Session Key

    The plug stores the serialized context under `"__sentry_lv_ctx__"` in the session.
    The context is small (just trace ID and span ID) and will naturally expire with the
    session. It's kept in the session so that WebSocket LiveView connections can
    restore the trace context.

    *Available since v10.8.0.*
    """

    @moduledoc since: "10.8.0"

    @behaviour Plug

    require Record

    @span_ctx_fields Record.extract(:span_ctx,
                       from_lib: "opentelemetry_api/include/opentelemetry.hrl"
                     )
    Record.defrecordp(:span_ctx, @span_ctx_fields)

    @session_key "__sentry_lv_ctx__"

    @impl Plug
    def init(opts), do: opts

    @impl Plug
    def call(conn, _opts) do
      # Get the trace carrier to store in session for LiveView processes
      carrier = get_trace_carrier(conn)

      # Only process if there's meaningful trace context
      if map_size(carrier) > 0 do
        # Check if we need to attach context (e.g., in tests where Bandit didn't run)
        # In production, Bandit will have already attached the context
        maybe_attach_context_from_headers(conn, carrier)

        Plug.Conn.put_session(conn, @session_key, carrier)
      else
        conn
      end
    end

    @doc false
    def session_key, do: @session_key

    # Only attach context if there's no valid span context already
    # This handles test scenarios where Bandit didn't run
    defp maybe_attach_context_from_headers(_conn, carrier) do
      current_span_ctx = :otel_tracer.current_span_ctx()

      if has_valid_span?(current_span_ctx) do
        # Bandit (or another transport) already set up the context, don't overwrite
        :ok
      else
        # No valid span context - extract from headers and attach
        # This is needed for tests using Phoenix.ConnTest
        ctx = :otel_ctx.get_current()

        new_ctx =
          Sentry.OpenTelemetry.Propagator.extract(
            ctx,
            carrier,
            &map_keys/1,
            &map_getter/2,
            []
          )

        _old_ctx = :otel_ctx.attach(new_ctx)
        :ok
      end
    end

    # Check if span context has a valid (non-zero) trace ID
    defp has_valid_span?(:undefined), do: false
    defp has_valid_span?(span_ctx(trace_id: trace_id)) when trace_id != 0, do: true
    defp has_valid_span?(_), do: false

    defp get_trace_carrier(conn) do
      # First, try to inject from current OTel context (set by transport)
      ctx = :otel_ctx.get_current()

      carrier =
        Sentry.OpenTelemetry.Propagator.inject(
          ctx,
          %{},
          &map_setter/3,
          []
        )

      if map_size(carrier) > 0 do
        carrier
      else
        # No context attached yet - try to extract from request headers
        # This handles test scenarios where the transport (Bandit) didn't run
        extract_from_headers(conn)
      end
    end

    defp extract_from_headers(conn) do
      # Build a carrier from conn headers
      headers_carrier = Map.new(conn.req_headers)

      # Check if we have trace headers
      if Map.has_key?(headers_carrier, "sentry-trace") or
           Map.has_key?(headers_carrier, "traceparent") do
        # Return the headers directly as the carrier - this will be extracted
        # in the LiveView process by the Propagator
        headers_carrier
      else
        %{}
      end
    end

    defp map_keys(carrier) do
      Map.keys(carrier)
    end

    defp map_getter(key, carrier) do
      case Map.fetch(carrier, key) do
        {:ok, value} -> value
        :error -> :undefined
      end
    end

    # Setter function for inject - builds a map of headers
    defp map_setter(key, value, carrier) do
      Map.put(carrier, key, value)
    end
  end
end
