defmodule Sentry.PlugCaptureTest do
  use ExUnit.Case
  use Plug.Test

  import Sentry.TestHelpers
  import ExUnit.CaptureLog

  defmodule PhoenixController do
    use Phoenix.Controller

    def error(_conn, _params), do: raise("PhoenixError")
    def exit(_conn, _params), do: exit(:test)
    def throw(_conn, _params), do: throw(:test)

    def action_clause_error(conn, %{"required_param" => true}) do
      send_resp(conn, 200, "")
    end

    def assigns(conn, _params) do
      _test = conn.assigns2.test
    end
  end

  defmodule PhoenixRouter do
    use Phoenix.Router

    get "/error_route", PhoenixController, :error
    get "/exit_route", PhoenixController, :exit
    get "/throw_route", PhoenixController, :throw
    get "/action_clause_error", PhoenixController, :action_clause_error
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

  setup_all do
    Application.put_env(:sentry, PhoenixEndpoint,
      render_errors: [view: Sentry.ErrorView, accepts: ~w(html)]
    )

    :ok
  end

  test "sends error to Sentry" do
    bypass = Bypass.open()

    Bypass.expect(bypass, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      _event = decode_event_from_envelope!(body)

      Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
    end)

    put_test_config(dsn: "http://public:secret@localhost:#{bypass.port}/1")

    assert_raise(Plug.Conn.WrapperError, "** (RuntimeError) Error", fn ->
      conn(:get, "/error_route")
      |> Sentry.ExamplePlugApplication.call([])
    end)
  end

  test "sends throws to Sentry" do
    bypass = Bypass.open()

    Bypass.expect(bypass, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      _event = decode_event_from_envelope!(body)

      Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
    end)

    put_test_config(dsn: "http://public:secret@localhost:#{bypass.port}/1")

    catch_throw(
      conn(:get, "/throw_route")
      |> Sentry.ExamplePlugApplication.call([])
    )
  end

  test "sends exits to Sentry" do
    bypass = Bypass.open()

    Bypass.expect(bypass, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      _event = decode_event_from_envelope!(body)

      Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
    end)

    put_test_config(dsn: "http://public:secret@localhost:#{bypass.port}/1")

    catch_exit(
      conn(:get, "/exit_route")
      |> Sentry.ExamplePlugApplication.call([])
    )
  end

  test "works with Sentry.PlugContext" do
    bypass = Bypass.open()

    Bypass.expect(bypass, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      event = decode_event_from_envelope!(body)

      assert event.request["url"] == "http://www.example.com/error_route"
      assert event.request["method"] == "GET"
      assert event.request["query_string"] == ""
      assert event.request["data"] == %{}
      Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
    end)

    put_test_config(dsn: "http://public:secret@localhost:#{bypass.port}/1")

    assert_raise(Plug.Conn.WrapperError, "** (RuntimeError) Error", fn ->
      conn(:get, "/error_route")
      |> Sentry.ExamplePlugApplication.call([])
    end)
  end

  test "does not send error on unmatched routes" do
    bypass = Bypass.open()

    Bypass.expect_once(bypass, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      _event = decode_event_from_envelope!(body)

      Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
    end)

    put_test_config(dsn: "http://public:secret@localhost:#{bypass.port}/1")

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

  describe "with errors in the Phoenix endpoint" do
    test "reports raised exceptions" do
      bypass = Bypass.open()

      Bypass.expect(bypass, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        event = decode_event_from_envelope!(body)

        assert event.culprit == "Sentry.PlugCaptureTest.PhoenixController.error/2"

        assert List.first(event.exception)["type"] == "RuntimeError"
        assert List.first(event.exception)["value"] == "PhoenixError"

        Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
      end)

      put_test_config(dsn: "http://public:secret@localhost:#{bypass.port}/1")

      {:ok, _} = PhoenixEndpoint.start_link()

      capture_log(fn ->
        assert_raise RuntimeError, "PhoenixError", fn ->
          conn(:get, "/error_route")
          |> PhoenixEndpoint.call([])
        end
      end)
    end

    test "reports exits" do
      bypass = Bypass.open()

      Bypass.expect(bypass, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        event = decode_event_from_envelope!(body)

        assert event.culprit == "Sentry.PlugCaptureTest.PhoenixController.exit/2"
        assert event.message == "Uncaught exit - :test"
        Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
      end)

      put_test_config(dsn: "http://public:secret@localhost:#{bypass.port}/1")

      {:ok, _} = PhoenixEndpoint.start_link()

      capture_log(fn ->
        catch_exit(conn(:get, "/exit_route") |> PhoenixEndpoint.call([]))
      end)
    end

    test "reports throws" do
      bypass = Bypass.open()

      Bypass.expect(bypass, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        event = decode_event_from_envelope!(body)

        assert event.culprit == "Sentry.PlugCaptureTest.PhoenixController.throw/2"
        assert event.message == "Uncaught throw - :test"
        Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
      end)

      put_test_config(dsn: "http://public:secret@localhost:#{bypass.port}/1")

      {:ok, _} = PhoenixEndpoint.start_link()

      capture_log(fn ->
        catch_throw(conn(:get, "/throw_route") |> PhoenixEndpoint.call([]))
      end)
    end
  end

  describe "with specific Phoenix errors" do
    @tag :capture_log
    test "does not send Phoenix.Router.NoRouteError" do
      start_supervised!(PhoenixEndpoint)

      assert_raise Phoenix.Router.NoRouteError, ~r"no route found for GET /not_found", fn ->
        conn(:get, "/not_found")
        |> Plug.run([{PhoenixEndpoint, []}])
      end
    end

    test "scrubs Phoenix.ActionClauseError" do
      bypass = Bypass.open()
      test_pid = self()
      ref = make_ref()

      Bypass.expect(bypass, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {ref, body})
        Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
      end)

      put_test_config(dsn: "http://public:secret@localhost:#{bypass.port}/1")

      start_supervised!(PhoenixEndpoint)

      assert_raise Phoenix.ActionClauseError, fn ->
        conn(:get, "/action_clause_error?password=secret")
        |> Plug.Conn.put_req_header("authorization", "yes")
        |> Plug.run([{PhoenixEndpoint, []}])
      end

      assert_receive {^ref, sentry_body}
      event = decode_event_from_envelope!(sentry_body)

      assert event.culprit == "Sentry.PlugCaptureTest.PhoenixController.action_clause_error/2"
      assert [exception] = event.exception
      assert exception["type"] == "Phoenix.ActionClauseError"
      assert exception["value"] =~ ~s(params: %{"password" => "*********"})
    end
  end

  test "can render feedback form in Phoenix ErrorView" do
    bypass = Bypass.open()

    Bypass.expect(bypass, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      _event = decode_event_from_envelope!(body)

      Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
    end)

    put_test_config(dsn: "http://public:secret@localhost:#{bypass.port}/1")

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

  test "can render feedback form in Plug application" do
    bypass = Bypass.open()

    Bypass.expect(bypass, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      _event = decode_event_from_envelope!(body)

      Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
    end)

    put_test_config(dsn: "http://public:secret@localhost:#{bypass.port}/1")

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
      event = decode_event_from_envelope!(body)
      assert event.culprit == "Sentry.PlugCaptureTest.PhoenixController.assigns/2"
      Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
    end)

    put_test_config(dsn: "http://public:secret@localhost:#{bypass.port}/1")

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
