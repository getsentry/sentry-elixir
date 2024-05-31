if Code.ensure_loaded?(Phoenix.LiveView) do
  defmodule Sentry.LiveViewHook do
    @moduledoc """
    A module that provides a `Phoenix.LiveView` hook to add Sentry context and breadcrumbs.

    *Available since v10.5.0.*

    This module sets context and breadcrumbs for the live view process through
    `Sentry.Context`. It sets things like:

      * The request URL
      * The user agent and user's IP address
      * Breadcrumbs for events that happen within LiveView

    To make this module work best, you'll need to fetch information from the LiveView's
    WebSocket. You can do that when calling the `socket/3` macro in your Phoenix endpoint.
    For example:

        socket "/live", Phoenix.LiveView.Socket,
          websocket: [connect_info: [:peer_data, :uri, :user_agent]]

    ## Examples

        defmodule MyApp.UserLive do
          use Phoenix.LiveView

          on_mount Sentry.LiveViewHook

          # ...
        end

    You can do the same at the router level:

        live_session :default, on_mount: Sentry.LiveViewHook do
          scope "..." do
            # ...
          end
        end

    You can also set this in your `MyAppWeb` module, so that all LiveViews that
    `use MyAppWeb, :live_view` will have this hook.
    """

    @moduledoc since: "10.5.0"

    import Phoenix.LiveView, only: [attach_hook: 4, get_connect_info: 2]

    alias Sentry.Context

    require Logger

    # See also:
    # https://develop.sentry.dev/sdk/event-payloads/request/

    @doc false
    @spec on_mount(:default, map(), map(), struct()) :: {:cont, struct()}
    def on_mount(:default, params, _session, socket), do: on_mount(params, socket)

    ## Helpers

    defp on_mount(params, %Phoenix.LiveView.Socket{} = socket) do
      Context.set_extra_context(%{socket_id: socket.id})
      Context.set_request_context(%{url: socket.host_uri})

      Context.add_breadcrumb(%{
        category: "web.live_view.mount",
        message: "Mounted live view",
        data: params
      })

      if uri = get_connect_info_if_root(socket, :uri) do
        Context.set_request_context(%{url: URI.to_string(uri)})
      end

      if user_agent = get_connect_info_if_root(socket, :user_agent) do
        Context.set_extra_context(%{user_agent: user_agent})
      end

      # :peer_data returns t:Plug.Conn.Adapter.peer_data/0.
      # https://hexdocs.pm/plug/Plug.Conn.Adapter.html#t:peer_data/0
      if ip_address = socket |> get_connect_info_if_root(:peer_data) |> get_safe_ip_address() do
        Context.set_user_context(%{ip_address: ip_address})
      end

      socket
      |> maybe_attach_hook_handle_params()
      |> attach_hook(__MODULE__, :handle_event, &handle_event_hook/3)
      |> attach_hook(__MODULE__, :handle_info, &handle_info_hook/2)
    catch
      # We must NEVER raise an error in a hook, as it will crash the LiveView process
      # and we don't want Sentry to be responsible for that.
      kind, reason ->
        Logger.error(
          "Sentry.LiveView.on_mount hook errored out: #{Exception.format(kind, reason)}",
          event_source: :logger
        )

        {:cont, socket}
    else
      socket -> {:cont, socket}
    end

    defp handle_event_hook(event, params, socket) do
      Context.add_breadcrumb(%{
        category: "web.live_view.event",
        message: inspect(event),
        data: %{event: event, params: params}
      })

      {:cont, socket}
    end

    defp handle_info_hook(message, socket) do
      Context.add_breadcrumb(%{
        category: "web.live_view.info",
        message: inspect(message, pretty: true)
      })

      {:cont, socket}
    end

    defp handle_params_hook(params, uri, socket) do
      Context.set_extra_context(%{socket_id: socket.id})
      Context.set_request_context(%{url: uri})

      Context.add_breadcrumb(%{
        category: "web.live_view.params",
        message: "#{uri}",
        data: %{params: params, uri: uri}
      })

      {:cont, socket}
    end

    defp get_connect_info_if_root(socket, key) do
      case socket.parent_pid do
        nil -> get_connect_info(socket, key)
        pid when is_pid(pid) -> nil
      end
    end

    defp maybe_attach_hook_handle_params(socket) do
      case socket.parent_pid do
        nil -> attach_hook(socket, __MODULE__, :handle_params, &handle_params_hook/3)
        pid when is_pid(pid) -> socket
      end
    end

    defp get_safe_ip_address(%{ip_address: ip} = _peer_data) do
      case :inet.ntoa(ip) do
        ip_address when is_list(ip_address) -> List.to_string(ip_address)
        {:error, _reason} -> nil
      end
    catch
      _kind, _reason -> nil
    end

    defp get_safe_ip_address(_peer_data) do
      nil
    end
  end
end
