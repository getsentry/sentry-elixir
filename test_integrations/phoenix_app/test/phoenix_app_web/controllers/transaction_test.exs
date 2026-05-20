defmodule Sentry.Integrations.Phoenix.TransactionTest do
  use PhoenixAppWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Sentry.TestHelpers
  import Sentry.Test.Assertions

  setup do
    Sentry.Test.setup_sentry(collect_envelopes: true, traces_sample_rate: 1.0)
  end

  test "GET /transaction", %{conn: conn, ref: ref} do
    get(conn, ~p"/transaction")

    tx =
      assert_sentry_transaction(ref,
        transaction: "test_span",
        transaction_info: %{"source" => "custom"},
        contexts: %{trace: %{origin: "phoenix_app", op: "test_span"}}
      )

    assert tx["contexts"]["trace"]["data"] == %{}
  end

  test "GET /users", %{conn: conn, ref: ref} do
    get(conn, ~p"/users")

    assert [mount_tx, handle_params_tx] = collect_sentry_transactions(ref, 2)

    assert_sentry_report(mount_tx,
      transaction: "PhoenixAppWeb.UserLive.Index.mount",
      transaction_info: %{"source" => "custom"},
      contexts: %{
        trace: %{origin: "opentelemetry_phoenix", op: "PhoenixAppWeb.UserLive.Index.mount"}
      }
    )

    assert mount_tx["contexts"]["trace"]["data"] == %{}

    assert [span_ecto] = mount_tx["spans"]

    assert span_ecto["op"] == "db"

    assert span_ecto["description"] ==
             "SELECT u0.\"id\", u0.\"name\", u0.\"age\", u0.\"inserted_at\", u0.\"updated_at\" FROM \"users\" AS u0"

    assert_sentry_report(handle_params_tx,
      transaction: "PhoenixAppWeb.UserLive.Index.handle_params",
      transaction_info: %{"source" => "custom"},
      contexts: %{
        trace: %{
          origin: "opentelemetry_phoenix",
          op: "PhoenixAppWeb.UserLive.Index.handle_params"
        }
      }
    )

    assert handle_params_tx["contexts"]["trace"]["data"] == %{}
  end

  test "GET /nested-spans includes grand-child spans", %{conn: conn, ref: ref} do
    get(conn, ~p"/nested-spans")

    tx =
      assert_sentry_transaction(ref,
        transaction: "root_span",
        transaction_info: %{"source" => "custom"},
        contexts: %{trace: %{origin: "phoenix_app", op: "root_span"}}
      )

    assert length(tx["spans"]) == 6

    span_names = Enum.map(tx["spans"], & &1["description"])

    assert "child_span_1" in span_names
    assert "child_span_2" in span_names
    assert "grandchild_span_1" in span_names
    assert "grandchild_span_2" in span_names
    assert "grandchild_span_3" in span_names

    db_spans = Enum.filter(tx["spans"], &(&1["op"] == "db"))
    assert length(db_spans) == 1

    [db_span] = db_spans
    assert String.starts_with?(db_span["description"], "SELECT")
    assert db_span["data"]["db.system"] == "sqlite"

    root_span_id = tx["contexts"]["trace"]["span_id"]
    child_spans = Enum.filter(tx["spans"], &(&1["parent_span_id"] == root_span_id))
    assert length(child_spans) == 2

    child_span_ids = MapSet.new(child_spans, & &1["span_id"])

    grandchild_spans =
      Enum.filter(tx["spans"], fn span ->
        span["parent_span_id"] != root_span_id and span["parent_span_id"] in child_span_ids
      end)

    assert length(grandchild_spans) == 3
  end

  test "LiveView mount and handle_params create disconnected transactions with child spans", %{
    conn: conn,
    ref: ref
  } do
    get(conn, ~p"/users")

    assert [mount_tx, handle_params_tx] = collect_sentry_transactions(ref, 2)

    assert mount_tx["transaction"] == "PhoenixAppWeb.UserLive.Index.mount"
    assert length(mount_tx["spans"]) == 1

    [mount_db_span] = mount_tx["spans"]
    assert mount_db_span["op"] == "db"
    assert mount_db_span["parent_span_id"] == mount_tx["contexts"]["trace"]["span_id"]

    assert handle_params_tx["transaction"] == "PhoenixAppWeb.UserLive.Index.handle_params"

    assert handle_params_tx["contexts"]["trace"]["span_id"] !=
             mount_tx["contexts"]["trace"]["span_id"]

    assert handle_params_tx["contexts"]["trace"]["trace_id"] !=
             mount_tx["contexts"]["trace"]["trace_id"]
  end

  describe "distributed tracing with sentry-trace header" do
    test "LiveView mount inherits trace context from sentry-trace header", %{
      conn: conn,
      ref: ref
    } do
      trace_id = "1234567890abcdef1234567890abcdef"
      parent_span_id = "abcdef1234567890"

      conn =
        conn
        |> put_req_header("sentry-trace", "#{trace_id}-#{parent_span_id}-1")

      get(conn, ~p"/users")

      transactions = collect_sentry_transactions(ref, 2)

      find_sentry_report!(transactions,
        transaction: "PhoenixAppWeb.UserLive.Index.mount",
        contexts: %{trace: %{trace_id: trace_id, parent_span_id: parent_span_id}}
      )

      find_sentry_report!(transactions,
        transaction: "PhoenixAppWeb.UserLive.Index.handle_params",
        contexts: %{trace: %{trace_id: trace_id, parent_span_id: parent_span_id}}
      )
    end

    test "LiveView handle_event in WebSocket shares trace context with initial request", %{
      conn: conn,
      ref: ref
    } do
      trace_id = "fedcba0987654321fedcba0987654321"
      parent_span_id = "1234567890fedcba"

      conn =
        conn
        |> put_req_header("sentry-trace", "#{trace_id}-#{parent_span_id}-1")

      {:ok, view, _html} = live(conn, ~p"/tracing-test")

      view |> element("#increment-btn") |> render_click()

      find_sentry_transaction!(ref,
        count: 5,
        timeout: 2000,
        transaction: ~r/handle_event#increment/,
        contexts: %{trace: %{trace_id: trace_id}}
      )
    end

    test "baggage header is preserved through LiveView lifecycle", %{conn: conn, ref: ref} do
      trace_id = "abababababababababababababababab"
      parent_span_id = "cdcdcdcdcdcdcdcd"
      baggage = "sentry-environment=production,sentry-release=1.0.0"

      conn =
        conn
        |> put_req_header("sentry-trace", "#{trace_id}-#{parent_span_id}-1")
        |> put_req_header("baggage", baggage)

      get(conn, ~p"/users")

      find_sentry_transaction!(ref,
        count: 2,
        transaction: "PhoenixAppWeb.UserLive.Index.mount",
        contexts: %{trace: %{trace_id: trace_id}}
      )
    end
  end
end
