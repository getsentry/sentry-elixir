defmodule Sentry.Integrations.Phoenix.ExceptionTest do
  use PhoenixAppWeb.ConnCase, async: false

  import Sentry.Test.Assertions

  setup do
    Sentry.Test.setup_sentry(collect_envelopes: true, traces_sample_rate: 1.0)
  end

  test "GET /exception sends exception to Sentry", %{conn: conn} do
    assert_raise RuntimeError, "Test exception", fn ->
      get(conn, ~p"/exception")
    end

    event =
      assert_sentry_report(:event,
        level: :error,
        original_exception: %RuntimeError{message: "Test exception"}
      )

    assert is_binary(event.event_id)
  end

  test "GET /traced-exception links the exception to the trace it was reported in", %{
    conn: conn,
    ref: ref
  } do
    get(conn, ~p"/traced-exception")

    event =
      assert_sentry_report(:event,
        original_exception: %RuntimeError{message: "Traced exception"}
      )

    transaction = find_sentry_transaction!(ref, count: 2, transaction: "process_order")

    assert event.contexts.trace.trace_id == transaction["contexts"]["trace"]["trace_id"]
    assert event.contexts.trace.span_id == transaction["contexts"]["trace"]["span_id"]
  end
end
