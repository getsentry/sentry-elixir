defmodule Sentry.TestPlugApplications do
  defmodule Example do
    use Plug.Router

    plug Plug.Parsers, parsers: [:multipart]
    plug :match
    plug :dispatch

    get "/error_route" do
      _ = conn
      raise RuntimeError, "Error"
    end

    post "/error_route" do
      _ = conn
      raise RuntimeError, "Error"
    end

    get "/spawn_error_route" do
      spawn(fn ->
        raise "Error"
      end)

      send_resp(conn, 200, "")
    end

    match "/error_route" do
      _ = conn
      raise RuntimeError, "Error"
    end
  end

  defmodule CustomCookieScrubber do
    use Plug.Router
    use Plug.ErrorHandler
    use Sentry.Plug, cookie_scrubber: fn(conn) ->
      Map.take(conn.req_cookies, ["regular"])
    end
    plug :match
    plug :dispatch
    forward("/", to: Sentry.TestPlugApplications.Example)
  end

  defmodule CollectFeedback do
    use Plug.Router
    use Plug.ErrorHandler
    use Sentry.Plug, collect_feedback: [enabled: true, options: %{title: "abc-123"}]
    plug :match
    plug :dispatch
    forward("/", to: Sentry.TestPlugApplications.Example)
  end

  defmodule Override do
    use Plug.Router
    use Plug.ErrorHandler
    use Sentry.Plug
    plug :match
    plug :dispatch
    forward("/", to: Sentry.TestPlugApplications.Example)

    defp handle_errors(conn, %{kind: _kind, reason: _reason, stack: _stack} = error) do
      super(conn, error)
      send_resp(conn, conn.status, "Something went terribly wrong")
    end
  end

  defmodule DefaultConfig do
    use Plug.Router
    use Plug.ErrorHandler
    use Sentry.Plug
    plug :match
    plug :dispatch
    forward("/", to: Sentry.TestPlugApplications.Example)
  end

  defmodule ScrubbingWithFile do
    use Plug.Router
    use Plug.ErrorHandler
    use Sentry.Plug
    plug :match
    plug :dispatch
    forward("/", to: Sentry.TestPlugApplications.Example)
  end
end
