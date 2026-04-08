defmodule Sentry.Integrations.Phoenix.ExceptionTest do
  use PhoenixAppWeb.ConnCase, async: true

  import Sentry.TestHelpers

  setup do
    %{bypass: bypass} = setup_bypass(traces_sample_rate: 1.0)

    Bypass.stub(bypass, "POST", "/api/1/envelope/", fn conn ->
      Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
    end)

    :ok
  end

  test "GET /exception sends exception to Sentry", %{conn: conn} do
    assert_raise RuntimeError, "Test exception", fn ->
      get(conn, ~p"/exception")
    end

    assert {event_id, _source} = Sentry.get_last_event_id_and_source()
    assert is_binary(event_id)
  end
end
