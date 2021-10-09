defmodule Sentry.PlugCaptureTest do
  use ExUnit.Case
  use Plug.Test
  import Sentry.TestEnvironmentHelper
  import ExUnit.CaptureLog
  alias Sentry.Envelope

  defmodule PhoenixController do
    use Phoenix.Controller
    def error(_conn, _params), do: raise("PhoenixError")
    def exit(_conn, _params), do: exit(:test)
    def throw(_conn, _params), do: throw(:test)

    def assigns(conn, _params) do
      _test = conn.assigns2.test
    end
  end

  defmodule PhoenixRouter do
    use Phoenix.Router

    get "/error_route", PhoenixController, :error
    get "/exit_route", PhoenixController, :exit
    get "/throw_route", PhoenixController, :throw
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

    plug Sentry.PlugContext, body_scrubber: &PhoenixEndpoint.scrub_params/1

    plug PhoenixRouter

    def scrub_params(conn) do
      Sentry.PlugContext.default_body_scrubber(conn)
    end
  end

  test "sends error to Sentry" do
    bypass = Bypass.open()

    Bypass.expect(bypass, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      _event =
        body
        |> Envelope.from_binary!()
        |> Envelope.event()
      Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
    end)

    modify_env(:sentry, dsn: "http://public:secret@localhost:#{bypass.port}/1")

    assert_raise(Plug.Conn.WrapperError, "** (RuntimeError) Error", fn ->
      conn(:get, "/error_route")
      |> Sentry.ExamplePlugApplication.call([])
    end)
  end

  test "sends throws to Sentry" do
    bypass = Bypass.open()

    Bypass.expect(bypass, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      _event =
        body
        |> Envelope.from_binary!()
        |> Envelope.event()
      Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
    end)

    modify_env(:sentry, dsn: "http://public:secret@localhost:#{bypass.port}/1")

    catch_throw(
      conn(:get, "/throw_route")
      |> Sentry.ExamplePlugApplication.call([])
    )
  end

  test "sends exits to Sentry" do
    bypass = Bypass.open()

    Bypass.expect(bypass, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      _event =
        body
        |> Envelope.from_binary!()
        |> Envelope.event()
      Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
    end)

    modify_env(:sentry, dsn: "http://public:secret@localhost:#{bypass.port}/1")

    catch_exit(
      conn(:get, "/exit_route")
      |> Sentry.ExamplePlugApplication.call([])
    )
  end

  test "works with Sentry.PlugContext" do
    bypass = Bypass.open()

    Bypass.expect(bypass, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      event =
        body
        |> Envelope.from_binary!()
        |> Envelope.event()
      assert event.request["url"] == "http://www.example.com/error_route"
      assert event.request["method"] == "GET"
      assert event.request["query_string"] == ""
      assert event.request["data"] == %{}
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
      _event =
        body
        |> Envelope.from_binary!()
        |> Envelope.event()
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
      event =
        body
        |> Envelope.from_binary!()
        |> Envelope.event()
      assert event.culprit == "Sentry.PlugCaptureTest.PhoenixController.error/2"
      assert event.message == "(RuntimeError PhoenixError)"
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

  test "reports exits occurring in Phoenix Endpoint" do
    bypass = Bypass.open()

    Bypass.expect(bypass, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      event =
        body
        |> Envelope.from_binary!()
        |> Envelope.event()
      assert event.culprit == "Sentry.PlugCaptureTest.PhoenixController.exit/2"
      assert event.message == "Uncaught exit - :test"
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
      catch_exit(conn(:get, "/exit_route") |> PhoenixEndpoint.call([]))
    end)
  end

  test "reports throws occurring in Phoenix Endpoint" do
    bypass = Bypass.open()

    Bypass.expect(bypass, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      event =
        body
        |> Envelope.from_binary!()
        |> Envelope.event()
      assert event.culprit == "Sentry.PlugCaptureTest.PhoenixController.throw/2"
      assert event.message == "Uncaught throw - :test"
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
      catch_throw(conn(:get, "/throw_route") |> PhoenixEndpoint.call([]))
    end)
  end

  test "can render feedback form in Phoenix ErrorView" do
    bypass = Bypass.open()

    Bypass.expect(bypass, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      _event =
        body
        |> Envelope.from_binary!()
        |> Envelope.event()
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
      _event =
        body
        |> Envelope.from_binary!()
        |> Envelope.event()
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
      _event =
        body
        |> Envelope.from_binary!()
        |> Envelope.event()
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
      event =
        body
        |> Envelope.from_binary!()
        |> Envelope.event()
      assert event.culprit == "Sentry.PlugCaptureTest.PhoenixController.assigns/2"
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
