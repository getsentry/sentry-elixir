defmodule Sentry.Integrations.Phoenix.TransactionTest do
  use PhoenixAppWeb.ConnCase, async: true

  import Sentry.TestHelpers

  setup do
    put_test_config(dsn: "http://public:secret@localhost:8080/1")

    Sentry.Test.start_collecting_sentry_reports()
  end

  test "GET /transaction", %{conn: conn} do
    get(conn, ~p"/transaction")

    transactions = Sentry.Test.pop_sentry_transactions()

    assert length(transactions) == 1

    assert [transaction] = transactions

    assert transaction.transaction == "Elixir.PhoenixAppWeb.PageController#transaction"
    assert transaction.transaction_info == %{source: "view"}

    trace = transaction.contexts.trace
    assert trace.origin == "opentelemetry_phoenix"
    assert trace.op == "http.server"
    assert trace.data == %{"http.response.status_code" => 200}
    assert trace.status == "ok"

    assert transaction.request.env == %{"SERVER_NAME" => "www.example.com", "SERVER_PORT" => 80}
    assert transaction.request.url == "http://www.example.com/transaction"
    assert transaction.request.method == "GET"

    assert [span] = transaction.spans

    assert span.op == "test_span"
    assert span.trace_id == trace.trace_id
    assert span.parent_span_id == trace.span_id
  end

  test "GET /users", %{conn: conn} do
    get(conn, ~p"/users")

    transactions = Sentry.Test.pop_sentry_transactions()

    assert length(transactions) == 1

    assert [transaction] = transactions

    assert transaction.transaction == "Elixir.PhoenixAppWeb.PageController#users"
    assert transaction.transaction_info == %{source: "view"}

    trace = transaction.contexts.trace
    assert trace.origin == "opentelemetry_phoenix"
    assert trace.op == "http.server"
    assert trace.data == %{"http.response.status_code" => 200}
    assert trace.status == "ok"

    assert transaction.request.env == %{"SERVER_NAME" => "www.example.com", "SERVER_PORT" => 80}
    assert transaction.request.url == "http://www.example.com/users"
    assert transaction.request.method == "GET"

    assert [span] = transaction.spans

    assert span.op == "db.sql.ecto"
    assert String.starts_with?(span.description, "SELECT ")
    assert span.trace_id == trace.trace_id
    assert span.parent_span_id == trace.span_id
  end
end
