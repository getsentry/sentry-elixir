defmodule Sentry.Integrations.Phoenix.ExceptionTest do
  use PhoenixAppWeb.ConnCase, async: true

  import Sentry.TestHelpers

  setup do
    bypass = Bypass.open()
    put_test_config(dsn: "http://public:secret@localhost:#{bypass.port}/1")
    %{bypass: bypass}
  end

  test "GET /exception sends exception to Sentry", %{conn: conn, bypass: bypass} do
    Bypass.expect(bypass, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert body =~ "RuntimeError"
      assert body =~ "Test exception"
      assert conn.request_path == "/api/1/envelope/"
      assert conn.method == "POST"
      Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
    end)

    assert_raise RuntimeError, "Test exception", fn ->
      get(conn, ~p"/exception")
    end

    assert {event_id, _source} = Sentry.get_last_event_id_and_source()
    assert is_binary(event_id)
  end
end
