if Sentry.OpenTelemetry.VersionChecker.tracing_compatible?() and
     Code.ensure_loaded?(Phoenix.LiveView) do
  defmodule Sentry.OpenTelemetry.LiveViewPropagator do
    @moduledoc """
    Telemetry handler that propagates OpenTelemetry context to LiveView processes.

    This module attaches telemetry handlers for LiveView lifecycle events
    (mount, handle_params, handle_event) that run BEFORE `opentelemetry_phoenix`
    creates spans, ensuring the correct parent trace context is attached.

    ## Why This Is Needed

    When a browser makes an HTTP request with distributed tracing headers, the trace
    context is correctly extracted for the initial request. However, Phoenix LiveView
    spawns new BEAM processes for lifecycle callbacks.

    `opentelemetry_phoenix` uses telemetry handlers to create spans for these events.
    If we don't inject the parent context BEFORE those handlers run, each LiveView
    span becomes a new root trace.

    This module solves this by:
    1. Attaching telemetry handlers with a lower priority (registered first)
    2. Storing the trace context in process dictionary via `Sentry.Plug.LiveViewContext`
    3. Extracting and attaching the context before `opentelemetry_phoenix` creates spans

    ## Usage

    Call `setup/0` in your application's start function, **BEFORE** calling
    `OpentelemetryPhoenix.setup/1`:

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

    Also add `Sentry.Plug.LiveViewContext` to your router pipeline:

        pipeline :browser do
          plug :accepts, ["html"]
          plug :fetch_session
          # ... other plugs
          plug Sentry.Plug.LiveViewContext
        end

    *Available since v10.x.0.*
    """

    @moduledoc since: "10.8.0"

    require Logger

    @handler_id {__MODULE__, :live_view_context}

    @doc """
    Attaches telemetry handlers for LiveView context propagation.

    Must be called BEFORE `OpentelemetryPhoenix.setup/1` to ensure handlers
    run in the correct order.
    """
    @spec setup() :: :ok
    def setup do
      events = [
        [:phoenix, :live_view, :mount, :start],
        [:phoenix, :live_view, :handle_params, :start],
        [:phoenix, :live_view, :handle_event, :start],
        [:phoenix, :live_component, :handle_event, :start]
      ]

      _ =
        :telemetry.attach_many(
          @handler_id,
          events,
          &__MODULE__.handle_event/4,
          %{}
        )

      :ok
    end

    @doc """
    Detaches the telemetry handlers. Mainly useful for testing.
    """
    @spec teardown() :: :ok | {:error, :not_found}
    def teardown do
      :telemetry.detach(@handler_id)
    end

    @doc false
    def handle_event(_event, _measurements, %{socket: socket} = _meta, _config) do
      # During static render (HTTP request phase), we mark spans to be filtered
      # since the HTTP span already covers this phase. Real LiveView interactions
      # happen over WebSocket.
      if static_render?(socket) do
        # Store in process dict that this is a static render - the span processor
        # can check this to filter out redundant LiveView spans
        Process.put(:sentry_lv_static_render, true)
        :ok
      else
        # WebSocket connection - clear the static render flag and propagate context
        Process.delete(:sentry_lv_static_render)
        propagate_context_if_needed(socket)
      end
    end

    @doc """
    Returns true if the current process is handling a static LiveView render.
    Used by the span processor to filter redundant spans.
    """
    def static_render? do
      Process.get(:sentry_lv_static_render, false)
    end

    # Check if this is a static render (not connected via WebSocket)
    defp static_render?(socket) do
      # During static render, transport_pid is nil
      socket.transport_pid == nil
    end

    defp propagate_context_if_needed(socket) do
      # Try to get trace context from socket's private assigns
      case get_context_carrier(socket) do
        nil ->
          :ok

        carrier when is_map(carrier) and map_size(carrier) > 0 ->
          # Check if we already have an attached context with a valid span
          # If so, don't overwrite it (this happens during static renders)
          current_span_ctx = :otel_tracer.current_span_ctx()

          _ =
            unless has_valid_span?(current_span_ctx) do
              # Extract and attach the trace context
              ctx = :otel_ctx.get_current()

              new_ctx =
                Sentry.OpenTelemetry.Propagator.extract(
                  ctx,
                  carrier,
                  &map_keys/1,
                  &map_getter/2,
                  []
                )

              :otel_ctx.attach(new_ctx)
            end

          :ok

        _ ->
          :ok
      end
    end

    # Try to get the carrier from socket private assigns
    defp get_context_carrier(socket) do
      session_key = Sentry.Plug.LiveViewContext.session_key()

      # The session can be in different places depending on the connection type:
      # 1. WebSocket: socket.private.connect_info.session (map)
      # 2. Static render (test): socket.private.connect_info is a %Plug.Conn{}
      case socket do
        # WebSocket connection has session as a map
        %{private: %{connect_info: %{session: session}}} when is_map(session) ->
          Map.get(session, session_key)

        # Static render (Phoenix.LiveViewTest) has connect_info as Plug.Conn
        %{private: %{connect_info: %Plug.Conn{private: %{plug_session: session}}}}
        when is_map(session) ->
          Map.get(session, session_key)

        _ ->
          nil
      end
    end

    # Check if span context has a valid (non-zero) trace ID
    defp has_valid_span?(:undefined), do: false

    defp has_valid_span?(span_ctx) when is_tuple(span_ctx) do
      case span_ctx do
        {:span_ctx, trace_id, _span_id, _flags, _tracestate, _is_valid, _is_remote, _is_recording,
         _sdk}
        when trace_id != 0 ->
          true

        _other ->
          false
      end
    end

    defp map_keys(carrier), do: Map.keys(carrier)

    defp map_getter(key, carrier) do
      case Map.fetch(carrier, key) do
        {:ok, value} -> value
        :error -> :undefined
      end
    end
  end
end
