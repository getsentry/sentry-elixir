defmodule Sentry.ExamplePlugApplication do
  use Sentry.PlugCapture
  use Plug.Router

  plug Plug.Parsers, parsers: [:multipart, :urlencoded]
  plug Sentry.PlugContext
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
