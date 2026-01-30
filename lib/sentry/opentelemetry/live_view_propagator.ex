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
    spawns new BEAM processes for WebSocket connections that handle lifecycle callbacks.

    `opentelemetry_phoenix` uses telemetry handlers to create spans for these events.
    If we don't inject the parent context BEFORE those handlers run, each LiveView
    span becomes a new root trace instead of being nested under the original HTTP request.

    This module solves this by:
    1. Using `Sentry.Plug.LiveViewContext` to store trace context in the session during the initial HTTP request
    2. Attaching telemetry handlers with higher priority (registered first) than `opentelemetry_phoenix`
    3. Extracting the context from the session and attaching it before `opentelemetry_phoenix` creates spans

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

    *Available since v12.0.0.*
    """

    @moduledoc since: "12.0.0"

    require Logger
    require Record

    @span_ctx_fields Record.extract(:span_ctx,
                       from_lib: "opentelemetry_api/include/opentelemetry.hrl"
                     )
    Record.defrecordp(:span_ctx, @span_ctx_fields)

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
      case get_context_carrier(socket) do
        carrier when is_map(carrier) and map_size(carrier) > 0 ->
          current_span_ctx = :otel_tracer.current_span_ctx()

          # Extract and attach the trace context from the session if needed
          if has_valid_span?(current_span_ctx) do
            :ok
          else
            new_ctx =
              Sentry.OpenTelemetry.Propagator.extract(
                :otel_ctx.get_current(),
                carrier,
                &Map.keys/1,
                &map_getter/2,
                []
              )

            :otel_ctx.attach(new_ctx)
          end

        nil ->
          :ok
      end
    end

    # Try to get the carrier from socket private assigns
    defp get_context_carrier(socket) do
      session_key = Sentry.Plug.LiveViewContext.session_key()

      case socket do
        %{private: %{connect_info: %{session: session}}} when is_map(session) ->
          Map.get(session, session_key)

        _ ->
          nil
      end
    end

    # Check if span context has a valid (non-zero) trace ID
    defp has_valid_span?(span_ctx(trace_id: trace_id)) when trace_id != 0, do: true
    defp has_valid_span?(_), do: false

    defp map_getter(key, carrier) do
      case Map.fetch(carrier, key) do
        {:ok, value} -> value
        :error -> :undefined
      end
    end
  end
end
