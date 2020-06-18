defmodule Sentry.PlugCaptureTest do
  use ExUnit.Case
  use Plug.Test
  import Sentry.TestEnvironmentHelper

  defmodule PhoenixEndpoint do
    use Sentry.PlugCapture
    use Phoenix.Endpoint, otp_app: :sentry
    plug(:error)
    plug(Sentry.ExamplePlugApplication)

    def error(_conn, _opts) do
      raise "EndpointError"
    end
  end

  test "sends error to Sentry" do
    bypass = Bypass.open()

    Bypass.expect(bypass, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      _json = Jason.decode!(body)
      Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
    end)

    modify_env(:sentry, dsn: "http://public:secret@localhost:#{bypass.port}/1")

    assert_raise(Plug.Conn.WrapperError, "** (RuntimeError) Error", fn ->
      conn(:get, "/error_route")
      |> Sentry.ExamplePlugApplication.call([])
    end)
  end

  test "works with Sentry.PlugContext" do
    bypass = Bypass.open()

    Bypass.expect(bypass, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      json = Jason.decode!(body)
      assert json["request"]["url"] == "http://www.example.com/error_route"
      assert json["request"]["method"] == "GET"
      assert json["request"]["query_string"] == ""
      assert json["request"]["data"] == %{}
      Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
    end)

    modify_env(:sentry, dsn: "http://public:secret@localhost:#{bypass.port}/1")

    assert_raise(Plug.Conn.WrapperError, "** (RuntimeError) Error", fn ->
      conn(:get, "/error_route")
      |> Sentry.ExamplePlugApplication.call([])
    end)
  end

  test "does not send error on unmatched routes" do
    bypass = Bypass.open()

    Bypass.expect_once(bypass, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      _json = Jason.decode!(body)
      Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
    end)

    modify_env(:sentry, dsn: "http://public:secret@localhost:#{bypass.port}/1")

    assert_raise(Plug.Conn.WrapperError, "** (RuntimeError) Error", fn ->
      conn(:get, "/error_route")
      |> Sentry.ExamplePlugApplication.call([])
    end)

    assert_raise(
      FunctionClauseError,
      "no function clause matching in Sentry.ExamplePlugApplication.do_match/4",
      fn ->
        conn(:get, "/not_found")
        |> Sentry.ExamplePlugApplication.call([])
      end
    )
  end

  test "reports errors occurring in Phoenix Endpoint" do
    bypass = Bypass.open()

    Bypass.expect(bypass, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      json = Jason.decode!(body)
      assert json["culprit"] == "Sentry.PlugCaptureTest.PhoenixEndpoint.error/2"
      assert json["message"] == "(RuntimeError) EndpointError"
      Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
    end)

    modify_env(:sentry,
      dsn: "http://public:secret@localhost:#{bypass.port}/1",
      "#{__MODULE__.PhoenixEndpoint}": [
        render_errors: [view: Sentry.ErrorView, accepts: ~w(html)]
      ]
    )

    modify_env(:phoenix, format_encoders: [])
    {:ok, _} = PhoenixEndpoint.start_link()

    assert_raise RuntimeError, "EndpointError", fn ->
      conn(:get, "/")
      |> PhoenixEndpoint.call([])
    end
  end

  test "can render feedback form in Phoenix ErrorView" do
    bypass = Bypass.open()

    Bypass.expect(bypass, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      _json = Jason.decode!(body)
      Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
    end)

    modify_env(:sentry,
      dsn: "http://public:secret@localhost:#{bypass.port}/1",
      "#{__MODULE__.PhoenixEndpoint}": [
        render_errors: [view: Sentry.ErrorView, accepts: ~w(html)]
      ],
      phoenix: [format_encoders: []]
    )

    {:ok, _} = PhoenixEndpoint.start_link()

    conn = conn(:get, "/")

    assert_raise RuntimeError, "EndpointError", fn ->
      PhoenixEndpoint.call(conn, [])
    end

    {event_id, _} = Sentry.last_event_id_and_source()

    assert_received {:plug_conn, :sent}
    assert {500, _headers, body} = sent_resp(conn)
    assert body =~ "sentry-cdn"
    assert body =~ event_id
    assert body =~ ~s{"title":"Testing"}
  end

  test "can render feedback form in Plug application" do
    bypass = Bypass.open()

    Bypass.expect(bypass, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      _json = Jason.decode!(body)
      Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
    end)

    modify_env(:sentry, dsn: "http://public:secret@localhost:#{bypass.port}/1")

    conn = conn(:get, "/error_route")

    assert_raise(Plug.Conn.WrapperError, "** (RuntimeError) Error", fn ->
      Sentry.ExamplePlugApplication.call(conn, [])
    end)

    {event_id, _} = Sentry.last_event_id_and_source()

    assert_received {:plug_conn, :sent}
    assert {500, _headers, body} = sent_resp(conn)
    assert body =~ "sentry-cdn"
    assert body =~ event_id
    assert body =~ ~s{"title":"Testing"}
  end
end
