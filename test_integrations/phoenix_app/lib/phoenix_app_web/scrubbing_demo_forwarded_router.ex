defmodule PhoenixAppWeb.ScrubbingDemoForwardedRouter do
  use Phoenix.Router

  pipeline :browser do
    plug :accepts, ["html"]
  end

  scope "/", PhoenixAppWeb do
    pipe_through :browser

    get "/reset-password/:token", ScrubbingDemoController, :reset_password
  end
end
