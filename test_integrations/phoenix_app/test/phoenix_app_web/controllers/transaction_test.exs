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

  test "GET /nested-spans includes grand-child spans", %{conn: conn} do
    get(conn, ~p"/nested-spans")

    transactions = Sentry.Test.pop_sentry_transactions()

    assert length(transactions) == 1
    assert [transaction] = transactions

    assert transaction.transaction == "root_span"
    assert transaction.transaction_info == %{source: :custom}

    trace = transaction.contexts.trace
    assert trace.origin == "phoenix_app"
    assert trace.op == "root_span"

    assert length(transaction.spans) == 6

    span_names = Enum.map(transaction.spans, & &1.description)

    # Verify all expected spans are present
    assert "child_span_1" in span_names
    assert "child_span_2" in span_names
    assert "grandchild_span_1" in span_names
    assert "grandchild_span_2" in span_names
    assert "grandchild_span_3" in span_names

    # Find the database span
    db_spans = Enum.filter(transaction.spans, &(&1.op == "db"))
    assert length(db_spans) == 1

    [db_span] = db_spans
    assert String.starts_with?(db_span.description, "SELECT")
    assert db_span.data["db.system"] == :sqlite

    child_spans = Enum.filter(transaction.spans, &(&1.parent_span_id == transaction.span_id))
    assert length(child_spans) == 2

    child_span_ids = MapSet.new(child_spans, & &1.span_id)

    grandchild_spans = Enum.filter(transaction.spans, fn span ->
      span.parent_span_id != transaction.span_id and span.parent_span_id in child_span_ids
    end)

    assert length(grandchild_spans) == 3
  end

  test "LiveView mount and handle_params create disconnected transactions with child spans", %{conn: conn} do
    get(conn, ~p"/users")

    transactions = Sentry.Test.pop_sentry_transactions()

    assert length(transactions) == 2
    assert [mount_transaction, handle_params_transaction] = transactions

    assert mount_transaction.transaction == "PhoenixAppWeb.UserLive.Index.mount"
    assert length(mount_transaction.spans) == 1

    [mount_db_span] = mount_transaction.spans
    assert mount_db_span.op == "db"
    assert mount_db_span.parent_span_id == mount_transaction.span_id

    assert handle_params_transaction.transaction == "PhoenixAppWeb.UserLive.Index.handle_params"
    assert handle_params_transaction.span_id != mount_transaction.span_id
    assert handle_params_transaction.contexts.trace.trace_id != mount_transaction.contexts.trace.trace_id

    refute mount_transaction.contexts.trace.trace_id == handle_params_transaction.contexts.trace.trace_id
  end
end
