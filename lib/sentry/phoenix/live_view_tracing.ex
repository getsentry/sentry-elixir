if Code.ensure_loaded?(Phoenix.LiveView) and
     Sentry.OpenTelemetry.VersionChecker.tracing_compatible?() do
  defmodule Sentry.Phoenix.LiveViewTracing do
    @moduledoc """
    LiveView hook that attaches the propagated OpenTelemetry context saved by `Sentry.Plug.LiveViewContext`.

    Configure your router with `on_mount {Sentry.Phoenix.LiveViewTracing, :attach}` so that the LiveView
    process can deserialize the carrier written to the session, attach it to the process, and inherit the
    incoming trace ID for spans emitted by `opentelemetry_phoenix`.

    If the session key is missing (for example, when a LiveView spawns another LiveView), the hook falls
    back to `OpentelemetryProcessPropagator.fetch_parent_ctx/0` when the dependency is available.
    """

    alias OpenTelemetry.Ctx
    alias Sentry.OpenTelemetry.Propagator

    @session_key "__sentry_live_view_context__"
    @context_token_key :sentry_live_view_tracing_token

    @doc """
    Attach the propagated context to a LiveView process.
    """
    @spec on_mount(atom(), map(), map(), Phoenix.LiveView.Socket.t()) ::
            {:cont, Phoenix.LiveView.Socket.t()}
    def on_mount(:attach, _params, session, socket) do
      {:cont, maybe_attach_context(socket, session)}
    end

    defp maybe_attach_context(socket, session) do
      case Map.get(session, @session_key) do
        carrier when is_map(carrier) and carrier != %{} ->
          attach_context(socket, extract_context(carrier))

        _ ->
          attach_context(socket, fetch_parent_context())
      end
    end

    defp extract_context(carrier) do
      ctx = Ctx.get_current()
      keys_fun = fn _ -> Map.keys(carrier) end
      getter = fn key, _ -> Map.get(carrier, key, :undefined) end

      Propagator.extract(ctx, carrier, keys_fun, getter, [])
    end

    defp fetch_parent_context do
      module = :OpentelemetryProcessPropagator

      if Code.ensure_loaded?(module) do
        apply(module, :fetch_parent_ctx, [])
      else
        :undefined
      end
    end

    defp attach_context(socket, ctx) when ctx in [:undefined, nil] do
      socket
    end

    defp attach_context(socket, ctx) do
      token = Ctx.attach(ctx)
      %{socket | private: Map.put(socket.private, @context_token_key, token)}
    end
  end
end
