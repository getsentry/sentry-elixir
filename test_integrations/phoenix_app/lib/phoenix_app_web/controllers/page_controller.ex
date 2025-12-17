defmodule PhoenixAppWeb.PageController do
  use PhoenixAppWeb, :controller

  require OpenTelemetry.Tracer, as: Tracer

  alias PhoenixApp.{Repo, Accounts.User}

  def home(conn, _params) do
    render(conn, :home, layout: false)
  end

  def exception(_conn, _params) do
    raise "Test exception"
  end

  def transaction(conn, _params) do
    Tracer.with_span "test_span" do
      :timer.sleep(100)
    end

    render(conn, :home, layout: false)
  end

  def users(conn, _params) do
    Repo.all(User) |> Enum.map(& &1.name)

    render(conn, :home, layout: false)
  end

  def nested_spans(conn, _params) do
    Tracer.with_span "root_span" do
      Tracer.with_span "child_span_1" do
        Tracer.with_span "grandchild_span_1" do
          :timer.sleep(50)
        end

        Tracer.with_span "grandchild_span_2" do
          Repo.all(User) |> Enum.count()
        end
      end

      Tracer.with_span "child_span_2" do
        Tracer.with_span "grandchild_span_3" do
          :timer.sleep(30)
        end
      end
    end

    render(conn, :home, layout: false)
  end

  # E2E tracing test endpoints

  def api_error(_conn, _params) do
    raise ArithmeticError, "bad argument in arithmetic expression"
  end

  def health(conn, _params) do
    json(conn, %{status: "ok"})
  end

  def api_data(conn, _params) do
    Tracer.with_span "fetch_data" do
      users = Repo.all(User)

      Tracer.with_span "process_data" do
        user_count = length(users)

        first_user = Repo.get(User, 1)

        json(conn, %{
          message: "Data fetched successfully",
          data: %{
            user_count: user_count,
            first_user: if(first_user, do: first_user.name, else: nil),
            timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
          }
        })
      end
    end
  end
end
