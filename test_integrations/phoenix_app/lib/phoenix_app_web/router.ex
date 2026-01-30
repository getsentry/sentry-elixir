defmodule PhoenixAppWeb.Router do
  use PhoenixAppWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {PhoenixAppWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug Sentry.Plug.LiveViewContext
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug :put_cors_headers
  end

  defp put_cors_headers(conn, _opts) do
    conn
    |> put_resp_header("access-control-allow-origin", "*")
    |> put_resp_header("access-control-allow-methods", "GET, POST, PUT, DELETE, OPTIONS")
    |> put_resp_header("access-control-allow-headers", "content-type, authorization, sentry-trace, baggage")
  end

  scope "/", PhoenixAppWeb do
    pipe_through :browser

    get "/", PageController, :home
    get "/exception", PageController, :exception
    get "/transaction", PageController, :transaction
    get "/nested-spans", PageController, :nested_spans
    get "/logs", PageController, :logs_demo

    live "/test-worker", TestWorkerLive
    live "/tracing-test", TracingTestLive

    live "/users", UserLive.Index, :index
    live "/users/new", UserLive.Index, :new
    live "/users/:id/edit", UserLive.Index, :edit

    live "/users/:id", UserLive.Show, :show
    live "/users/:id/show/edit", UserLive.Show, :edit
  end

  # For e2e DT tests with a front-end app
  scope "/", PhoenixAppWeb do
    pipe_through :api

    get "/error", PageController, :api_error
    get "/health", PageController, :health
    get "/api/data", PageController, :api_data
  end

  # Other scopes may use custom stacks.
  # scope "/api", PhoenixAppWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:phoenix_app, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: PhoenixAppWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
