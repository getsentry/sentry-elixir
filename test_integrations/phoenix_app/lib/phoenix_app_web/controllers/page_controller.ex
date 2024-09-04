defmodule PhoenixAppWeb.PageController do
  use PhoenixAppWeb, :controller

  require OpenTelemetry.Tracer, as: Tracer

  alias PhoenixApp.{Repo, User}

  def home(conn, _params) do
    render(conn, :home, layout: false)
  end

  def exception(_conn, _params) do
    raise "Test exception"
  end

  def transaction(conn, _params) do
    Tracer.with_span("test_span") do
      :timer.sleep(100)
    end

    render(conn, :home, layout: false)
  end

  def users(conn, _params) do
    Repo.all(User) |> Enum.map(& &1.name)

    render(conn, :home, layout: false)
  end
end
