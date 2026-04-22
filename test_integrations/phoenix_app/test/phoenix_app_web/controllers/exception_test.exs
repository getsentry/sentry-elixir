defmodule Sentry.Integrations.Phoenix.ExceptionTest do
  use PhoenixAppWeb.ConnCase, async: false

  import Sentry.Test.Assertions

  setup do
    Sentry.Test.setup_sentry(traces_sample_rate: 1.0)
    :ok
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
end
