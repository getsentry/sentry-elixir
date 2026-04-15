defmodule PhoenixAppWeb.GraphQLController do
  use PhoenixAppWeb, :controller

  @absinthe_opts Absinthe.Plug.init(schema: PhoenixAppWeb.Schema)

  def execute(conn, _params) do
    Absinthe.Plug.call(conn, @absinthe_opts)
  end
end
