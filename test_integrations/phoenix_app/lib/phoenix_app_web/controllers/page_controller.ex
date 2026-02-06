defmodule PhoenixAppWeb.PageController do
  use PhoenixAppWeb, :controller

  require Logger
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

  # Test endpoint for structured logging with OpenTelemetry trace context
  #
  # This endpoint demonstrates how logs automatically include trace context
  # when using opentelemetry_logger_metadata. All logs within the traced spans
  # will include trace_id and span_id in the Sentry log events.
  #
  # To test:
  # 1. Start the Phoenix app: cd test_integrations/phoenix_app && iex -S mix phx.server
  # 2. Visit: http://localhost:4000/logs
  # 3. Check Sentry logs - they should have trace_id matching the transaction traces
  def logs_demo(conn, params) do
    request_id =
      get_req_header(conn, "x-request-id") |> List.first() || "demo-#{:rand.uniform(10000)}"

    user_id = Map.get(params, "user_id", 123)

    # Set logger metadata
    Logger.metadata(request_id: request_id, user_id: user_id)

    # Log at different levels with structured data
    Logger.info("User session started",
      action: "login",
      ip_address: to_string(:inet.ntoa(conn.remote_ip)),
      user_agent: get_req_header(conn, "user-agent") |> List.first()
    )

    Logger.debug("Processing user request",
      endpoint: "/logs",
      method: conn.method,
      query_params: params
    )

    # Simulate some work with nested spans and logging
    Tracer.with_span "process_logs_demo" do
      Logger.info("Inside traced span",
        span_name: "process_logs_demo",
        duration_hint: "will take ~100ms"
      )

      :timer.sleep(100)

      Tracer.with_span "database_query" do
        users = Repo.all(User)

        Logger.info("Database query completed",
          query: "SELECT * FROM users",
          result_count: length(users)
        )
      end
    end

    Logger.warning("Sample warning log",
      warning_type: "demo",
      severity: "low"
    )

    Logger.error("Sample error log (not an exception)",
      error_type: "demo",
      recoverable: true,
      retry_count: 0
    )

    # Force flush the log buffer immediately
    Sentry.LogEventBuffer.flush()

    json(conn, %{
      message: "Logs demo completed - check your Sentry logs!",
      info: %{
        request_id: request_id,
        user_id: user_id,
        logs_sent: "Multiple log events at info, debug, warning, and error levels",
        note: "These are structured log events, not error events",
        check: "Look for these logs in Sentry's Logs section (not Errors)",
        flushed: "Log buffer was flushed immediately"
      }
    })
  end
end
