defmodule Sentry.Integrations.Phoenix.ExceptionTest do
  use PhoenixAppWeb.ConnCase, async: true

  import Sentry.TestHelpers

  setup do
    put_test_config(dsn: "http://public:secret@localhost:8080/1")

    Sentry.Test.start_collecting_sentry_reports()
  end

  test "GET /exception sends exception to Sentry", %{conn: conn} do
    assert_raise RuntimeError, "Test exception", fn ->
      get(conn, ~p"/exception")
    end

    assert {event_id, _source} = Sentry.get_last_event_id_and_source()
    assert is_binary(event_id)
  end
end
