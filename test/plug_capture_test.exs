defmodule Sentry.PlugCaptureTest do
  use ExUnit.Case
  use Plug.Test
  import Sentry.TestEnvironmentHelper
  import ExUnit.CaptureLog

  defmodule PhoenixController do
    use Phoenix.Controller
    def error(_conn, _params), do: raise("PhoenixError")

    def assigns(conn, _params) do
      _test = conn.assigns2.test
    end
  end

  defmodule PhoenixRouter do
    use Phoenix.Router

    get "/error_route", PhoenixController, :error
    get "/assigns_route", PhoenixController, :assigns
  end

  defmodule PhoenixEndpoint do
    use Sentry.PlugCapture
    use Phoenix.Endpoint, otp_app: :sentry
    use Plug.Debugger, otp_app: :sentry

    plug Plug.Parsers,
      parsers: [:urlencoded, :multipart, :json],
      pass: ["*/*"],
      json_decoder: Jason

    plug Sentry.PlugContext

    plug PhoenixRouter
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
      assert json["culprit"] == "Sentry.PlugCaptureTest.PhoenixController.error/2"
      assert json["message"] == "(RuntimeError PhoenixError)"
      Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
    end)

    modify_env(:sentry,
      dsn: "http://public:secret@localhost:#{bypass.port}/1",
      "#{__MODULE__.PhoenixEndpoint}": [
        render_errors: [view: Sentry.ErrorView, accepts: ~w(html)]
      ]
    )

    {:ok, _} = PhoenixEndpoint.start_link()

    capture_log(fn ->
      assert_raise RuntimeError, "PhoenixError", fn ->
        conn(:get, "/error_route")
        |> PhoenixEndpoint.call([])
      end
    end)
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
      ]
    )

    {:ok, _} = PhoenixEndpoint.start_link()

    conn = conn(:get, "/error_route")

    capture_log(fn ->
      assert_raise RuntimeError, "PhoenixError", fn ->
        PhoenixEndpoint.call(conn, [])
      end
    end)

    {event_id, _} = Sentry.get_last_event_id_and_source()

    assert_received {:plug_conn, :sent}
    assert {500, _headers, body} = sent_resp(conn)
    assert body =~ "sentry-cdn"
    assert body =~ event_id
    assert body =~ ~s{"title":"Testing"}
  end

  test "does not send NoRouteError in Phoenix application" do
    bypass = Bypass.open()

    Bypass.expect_once(bypass, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      _json = Jason.decode!(body)
      Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
    end)

    modify_env(:sentry,
      dsn: "http://public:secret@localhost:#{bypass.port}/1",
      "#{__MODULE__.PhoenixEndpoint}": [
        render_errors: [view: Sentry.ErrorView, accepts: ~w(html)]
      ]
    )

    {:ok, _} = PhoenixEndpoint.start_link()

    capture_log(fn ->
      assert_raise RuntimeError, "PhoenixError", fn ->
        conn(:get, "/error_route")
        |> PhoenixEndpoint.call([])
      end

      assert_raise(
        Phoenix.Router.NoRouteError,
        "no route found for GET /not_found (Sentry.PlugCaptureTest.PhoenixRouter)",
        fn ->
          conn(:get, "/not_found")
          |> PhoenixEndpoint.call([])
        end
      )
    end)
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

    assert_received {:plug_conn, :sent}
    {event_id, _} = Sentry.get_last_event_id_and_source()
    assert {500, _headers, body} = sent_resp(conn)
    assert body =~ "sentry-cdn"
    assert body =~ event_id
    assert body =~ ~s{"title":"Testing"}
  end

  test "handles Erlang error in Plug.Conn.WrapperError" do
    bypass = Bypass.open()

    Bypass.expect(bypass, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      json = Jason.decode!(body)
      assert json["culprit"] == "Sentry.PlugCaptureTest.PhoenixController.assigns/2"
      Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
    end)

    modify_env(:sentry,
      dsn: "http://public:secret@localhost:#{bypass.port}/1",
      "#{__MODULE__.PhoenixEndpoint}": [
        render_errors: [view: Sentry.ErrorView, accepts: ~w(html)]
      ]
    )

    {:ok, _} = PhoenixEndpoint.start_link()

    capture_log(fn ->
      assert_raise KeyError, fn ->
        conn(:get, "/assigns_route")
        |> Plug.Conn.put_req_header("throw", "throw")
        |> PhoenixEndpoint.call([])
      end
    end)
  end
end
