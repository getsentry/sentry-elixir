defmodule Sentry.Integrations.Phoenix.TransactionTest do
  use PhoenixAppWeb.ConnCase, async: false

  import Sentry.TestHelpers

  setup do
    put_test_config(dsn: "http://public:secret@localhost:8080/1", traces_sample_rate: 1.0)

    Sentry.Test.start_collecting_sentry_reports()
  end

  test "GET /transaction", %{conn: conn} do
    # TODO: Wrap this in a transaction that the web server usually
    # would wrap it in.
    get(conn, ~p"/transaction")

    transactions = Sentry.Test.pop_sentry_transactions()

    assert length(transactions) == 1

    assert [transaction] = transactions

    assert transaction.transaction == "test_span"
    assert transaction.transaction_info == %{source: :custom}

    trace = transaction.contexts.trace
    assert trace.origin == "phoenix_app"
    assert trace.op == "test_span"
    assert trace.data == %{}
  end

  test "GET /users", %{conn: conn} do
    get(conn, ~p"/users")

    transactions = Sentry.Test.pop_sentry_transactions()

    assert length(transactions) == 2

    assert [mount_transaction, handle_params_transaction] = transactions

    assert mount_transaction.transaction == "PhoenixAppWeb.UserLive.Index.mount"
    assert mount_transaction.transaction_info == %{source: :custom}

    trace = mount_transaction.contexts.trace
    assert trace.origin == "opentelemetry_phoenix"
    assert trace.op == "PhoenixAppWeb.UserLive.Index.mount"
    assert trace.data == %{}

    assert [span_ecto] = mount_transaction.spans

    assert span_ecto.op == "db"
    assert span_ecto.description == "SELECT u0.\"id\", u0.\"name\", u0.\"age\", u0.\"inserted_at\", u0.\"updated_at\" FROM \"users\" AS u0"

    assert handle_params_transaction.transaction ==
             "PhoenixAppWeb.UserLive.Index.handle_params"

    assert handle_params_transaction.transaction_info == %{source: :custom}

    trace = handle_params_transaction.contexts.trace
    assert trace.origin == "opentelemetry_phoenix"
    assert trace.op == "PhoenixAppWeb.UserLive.Index.handle_params"
    assert trace.data == %{}
  end
end
