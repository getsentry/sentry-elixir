defmodule Sentry.ExampleApp do
  use Plug.Router
  use Plug.ErrorHandler
  use Sentry.Plug, request_id_header: "x-request-id", cookie_scrubber: &Sentry.ExampleApp.allow_all_cookie_scrubber/1

  plug Plug.Parsers, parsers: [:multipart]
  plug Plug.RequestId
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

  def all_cookie_scrubber(conn) do
    conn.req_cookies
  end
end
