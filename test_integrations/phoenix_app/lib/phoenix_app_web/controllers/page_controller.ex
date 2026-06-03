defmodule PhoenixAppWeb.PageController do
  use PhoenixAppWeb, :controller

  require Logger
  require OpenTelemetry.Tracer, as: Tracer

  alias PhoenixApp.{Repo, Accounts.User}

  plug Sentry.PlugContext,
       [body_scrubber: {__MODULE__, :marker_body_scrubber}] when action == :function_clause_error

  plug Sentry.PlugContext, [] when action == :function_clause_error_default

  plug Sentry.PlugContext, [] when action == :function_clause_error_private
  plug :put_sensitive_private when action == :function_clause_error_private

  plug Sentry.PlugContext, [] when action == :function_clause_error_cleared
  plug :put_sensitive_assigns_and_cookies when action == :function_clause_error_cleared

  plug Sentry.PlugContext, [] when action == :generic_clause_error

  plug Sentry.PlugContext, [] when action == :checkout

  def home(conn, _params) do
    render(conn, :home, layout: false)
  end

  def exception(_conn, _params) do
    raise "Test exception"
  end

  def function_clause_error(_conn, %{"required" => _value}) do
    :ok
  end

  def function_clause_error_default(_conn, %{"required" => _value}) do
    :ok
  end

  def function_clause_error_private(_conn, %{"required" => _value}) do
    :ok
  end

  def function_clause_error_cleared(_conn, %{"required" => _value}) do
    :ok
  end

  # Fabricates a *generic* FunctionClauseError (NOT a Phoenix.ActionClauseError):
  # the action itself matches fine, then calls a private helper whose only clause
  # does not match the given argument. The sensitive data rides on that helper's
  # argument, so it surfaces in the captured stacktrace frame vars and must be
  # scrubbed there — independently of PlugCapture's ActionClauseError handling.
  def generic_clause_error(conn, _params) do
    build_widget(%{"password" => "raw-secret-password", "username" => "alice"})
    json(conn, %{})
  end

  defp build_widget(%{"required" => value}), do: value

  # A realistic checkout: build a %Billing.CreditCard{} value struct from the
  # payment form and hand it to the billing context. The currency here is one the
  # processor does not support, so PhoenixApp.Billing.charge/3 matches no clause
  # and raises a *generic* FunctionClauseError. The card struct rides along in that
  # frame's stacktrace args, where Sentry must scrub it before reporting.
  def checkout(conn, _params) do
    card = %PhoenixApp.Billing.CreditCard{
      cardholder: "Alice Example",
      number: "4242424242424242",
      cvv: "123"
    }

    PhoenixApp.Billing.charge(card, 4200, "ZZZ")
    json(conn, %{})
  end

  @doc false
  def marker_body_scrubber(_conn), do: %{"marker" => "custom-scrub-applied"}

  # Injects a non-allow-listed key into conn.private so the captured
  # Phoenix.ActionClauseError exercises the :private allow-list scrubbing: the
  # injected key must be dropped, while Phoenix's routing metadata is retained.
  defp put_sensitive_private(conn, _opts) do
    Plug.Conn.put_private(conn, :plug_session, %{
      "user_id" => 1,
      "csrf_token" => "secret-csrf-value"
    })
  end

  # Injects sensitive data into conn.assigns and req_cookies so the captured
  # Phoenix.ActionClauseError exercises the :clear strategy: both fields must be
  # cleared to %{} so none of this data reaches Sentry.
  defp put_sensitive_assigns_and_cookies(conn, _opts) do
    conn = Plug.Conn.assign(conn, :current_user, %{id: 1, password_hash: "secret-assigns-hash"})
    %{conn | req_cookies: %{"sid" => "secret-cookie-session"}}
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

  def metrics(conn, _params) do
    # Counter: track incoming requests with attributes
    Sentry.Metrics.count("http.requests", 1,
      unit: "request",
      attributes: %{method: conn.method, path: "/metrics"}
    )

    # Distribution: track request payload size
    content_length =
      case get_req_header(conn, "content-length") do
        [size] -> String.to_integer(size)
        _ -> 0
      end

    Sentry.Metrics.distribution("request.payload_size", content_length, unit: "byte")

    # Metrics inside a traced span get trace context automatically
    Tracer.with_span "fetch_users" do
      start_time = System.monotonic_time(:millisecond)
      users = Repo.all(User)
      duration = System.monotonic_time(:millisecond) - start_time

      Sentry.Metrics.gauge("users.count", length(users), unit: "user")
      Sentry.Metrics.distribution("db.query_time", duration, unit: "millisecond")
    end

    Sentry.flush()

    json(conn, %{message: "Metrics recorded"})
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
  def logs_with_structs(conn, _params) do
    Logger.metadata(
      uri: URI.parse("https://example.com/path"),
      conn_info: %{method: conn.method, path: conn.request_path},
      tags: [:web, :test]
    )

    Logger.info("Log with struct metadata")

    Sentry.flush()

    json(conn, %{message: "ok"})
  end

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

    # Force flush the telemetry processor immediately
    Sentry.flush()

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

  def api_oban_job(conn, params) do
    alias PhoenixApp.Workers.TestWorker

    sleep_time = Map.get(params, "sleep_time", "100") |> String.to_integer()
    should_fail = Map.get(params, "should_fail", "false") == "true"

    {:ok, job} =
      %{"sleep_time" => sleep_time, "should_fail" => should_fail}
      |> TestWorker.new()
      |> OpentelemetryOban.insert()

    json(conn, %{
      job_id: job.id,
      worker: job.worker,
      queue: job.queue,
      args: job.args,
      enqueued: true
    })
  end
end
