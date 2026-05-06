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

    ## Scrubbing Sensitive Data

    *Available since v13.1.0.*

    LiveView events and `handle_params` calls frequently carry user-submitted
    form data, which may include passwords or other sensitive values. Before
    storing this data in breadcrumbs, this hook scrubs it using
    `Sentry.Scrubber.scrub_map/2`. URI query strings stored in breadcrumbs are
    scrubbed via `Sentry.Scrubber.scrub_url/2`.

    To customize the scrubbing logic, pass a `:scrubber` option when attaching
    the hook. The scrubber must be a `{module, function, args}` tuple; the
    breadcrumb `data` map is prepended to `args` before invoking the function,
    which must return a map.

        on_mount {Sentry.LiveViewHook, scrubber: {MyApp.Scrubber, :scrub, []}}

    The default scrubber is equivalent to:

        {Sentry.LiveViewHook, :default_scrubber, []}

    """

    @moduledoc since: "10.5.0"

    import Phoenix.LiveView, only: [attach_hook: 4, get_connect_info: 2]

    alias Sentry.Context

    require Logger

    @scrubber_pdict_key {__MODULE__, :scrubber}

    # See also:
    # https://develop.sentry.dev/sdk/event-payloads/request/

    @doc false
    @spec on_mount(:default | keyword(), map() | :not_mounted_at_router, map(), struct()) ::
            {:cont, struct()}
    def on_mount(:default, params, session, socket),
      do: on_mount([], params, session, socket)

    def on_mount(opts, %{} = params, _session, socket) when is_list(opts) do
      store_scrubber(opts)
      on_mount(params, socket)
    end

    def on_mount(opts, :not_mounted_at_router, _session, socket) when is_list(opts) do
      store_scrubber(opts)
      {:cont, socket}
    end

    @doc """
    The default scrubber applied to LiveView breadcrumb data.

    Delegates to `Sentry.Scrubber.scrub_map/2` with the default sensitive
    parameter keys.
    """
    @doc since: "13.1.0"
    @spec default_scrubber(map()) :: map()
    def default_scrubber(data) when is_map(data) do
      Sentry.Scrubber.scrub_map(data)
    end

    ## Helpers

    defp store_scrubber(opts) do
      case Keyword.get(opts, :scrubber, {__MODULE__, :default_scrubber, []}) do
        {mod, fun, args} = scrubber when is_atom(mod) and is_atom(fun) and is_list(args) ->
          Process.put(@scrubber_pdict_key, scrubber)

        other ->
          raise ArgumentError,
                "expected :scrubber to be a {module, function, args} tuple, got: #{inspect(other)}"
      end
    end

    defp scrub(data) when is_map(data) do
      {mod, fun, args} =
        Process.get(@scrubber_pdict_key, {__MODULE__, :default_scrubber, []})

      case apply(mod, fun, [data | args]) do
        result when is_map(result) ->
          result

        other ->
          Logger.error(
            "Sentry.LiveViewHook scrubber returned non-map value: #{inspect(other)}; " <>
              "falling back to redacted data",
            event_source: :logger
          )

          %{}
      end
    end

    defp scrub_uri(uri) when is_binary(uri), do: Sentry.Scrubber.scrub_url(uri)

    defp on_mount(params, %Phoenix.LiveView.Socket{} = socket) do
      Context.set_extra_context(%{socket_id: socket.id})
      Context.set_request_context(%{url: socket.host_uri})

      Context.add_breadcrumb(%{
        category: "web.live_view.mount",
        message: "Mounted live view",
        data: scrub(params)
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
        data: scrub(%{event: event, params: params})
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
      scrubbed_uri = scrub_uri(uri)
      Context.set_extra_context(%{socket_id: socket.id})
      Context.set_request_context(%{url: scrubbed_uri})

      Context.add_breadcrumb(%{
        category: "web.live_view.params",
        message: "#{scrubbed_uri}",
        data: scrub(%{params: params, uri: scrubbed_uri})
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
