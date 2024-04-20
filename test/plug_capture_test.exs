defmodule Sentry.PlugCaptureTest do
  use Sentry.Case
  use Plug.Test

  import Sentry.TestHelpers

  defmodule PhoenixController do
    use Phoenix.Controller

    def error(_conn, _params), do: raise("PhoenixError")
    def exit(_conn, _params), do: exit(:test)
    def throw(_conn, _params), do: throw(:test)
    def action_clause_error(conn, %{"required_param" => true}), do: conn
    def assigns(conn, _params), do: _test = conn.assigns2.test
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

    plug Plug.Parsers, parsers: [:json], pass: ["*/*"], json_decoder: Jason
    plug Sentry.PlugContext
    plug PhoenixRouter
  end

  defmodule Scrubber do
    def scrub_conn(conn) do
      conn
    end
  end

  defmodule PhoenixEndpointWithScrubber do
    use Sentry.PlugCapture, scrubber: {Scrubber, :scrub_conn, []}
    use Phoenix.Endpoint, otp_app: :sentry
    use Plug.Debugger, otp_app: :sentry

    plug Plug.Parsers, parsers: [:json], pass: ["*/*"], json_decoder: Jason
    plug Sentry.PlugContext
    plug PhoenixRouter
  end

  setup do
    bypass = Bypass.open()
    put_test_config(dsn: "http://public:secret@localhost:#{bypass.port}/1")
    %{bypass: bypass}
  end

  describe "with a Plug application" do
    test "sends error to Sentry and uses Sentry.PlugContext to fill in context", %{
      bypass: bypass
    } do
      Bypass.expect(bypass, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        event = decode_event_from_envelope!(body)

        assert event["request"]["url"] == "http://www.example.com/error_route"
        assert event["request"]["method"] == "GET"
        assert event["request"]["query_string"] == ""
        assert event["request"]["data"] == %{}
        Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
      end)

      assert_raise(Plug.Conn.WrapperError, "** (RuntimeError) Error", fn ->
        conn(:get, "/error_route")
        |> call_plug_app()
      end)
    end

    test "sends throws to Sentry", %{bypass: bypass} do
      Bypass.expect(bypass, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        _event = decode_event_from_envelope!(body)
        Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
      end)

      catch_throw(conn(:get, "/throw_route") |> call_plug_app())
    end

    test "sends exits to Sentry", %{bypass: bypass} do
      Bypass.expect(bypass, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        _event = decode_event_from_envelope!(body)
        Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
      end)

      catch_exit(conn(:get, "/exit_route") |> call_plug_app())
    end

    test "does not send error on unmatched routes", %{bypass: _bypass} do
      assert_raise FunctionClauseError, ~r/no function clause matching/, fn ->
        conn(:get, "/not_found")
        |> call_plug_app()
      end
    end

    test "can render feedback form", %{bypass: bypass} do
      Bypass.expect(bypass, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        _event = decode_event_from_envelope!(body)
        Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
      end)

      conn = conn(:get, "/error_route")

      assert_raise Plug.Conn.WrapperError, "** (RuntimeError) Error", fn ->
        call_plug_app(conn)
      end

      assert_received {:plug_conn, :sent}
      {event_id, _} = Sentry.get_last_event_id_and_source()
      assert {500, _headers, body} = sent_resp(conn)
      assert body =~ "sentry-cdn"
      assert body =~ event_id
      assert body =~ ~s{"title":"Testing"}
    end
  end

  describe "with a Phoenix endpoint" do
    @describetag :capture_log

    setup do
      Application.put_env(:sentry, PhoenixEndpoint,
        render_errors: [view: Sentry.ErrorView, accepts: ~w(html)]
      )

      pid = start_supervised!(PhoenixEndpoint)
      Process.link(pid)

      :ok
    end

    test "reports raised exceptions", %{bypass: bypass} do
      Bypass.expect(bypass, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        event = decode_event_from_envelope!(body)

        assert event["culprit"] == "Sentry.PlugCaptureTest.PhoenixController.error/2"

        assert List.first(event["exception"])["type"] == "RuntimeError"
        assert List.first(event["exception"])["value"] == "PhoenixError"

        Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
      end)

      assert_raise RuntimeError, "PhoenixError", fn ->
        conn(:get, "/error_route")
        |> call_phoenix_endpoint()
      end
    end

    test "reports exits", %{bypass: bypass} do
      Bypass.expect(bypass, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        event = decode_event_from_envelope!(body)

        assert event["culprit"] == "Sentry.PlugCaptureTest.PhoenixController.exit/2"
        assert event["message"]["formatted"] == "Uncaught exit - :test"
        Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
      end)

      catch_exit(conn(:get, "/exit_route") |> call_phoenix_endpoint())
    end

    test "reports throws", %{bypass: bypass} do
      Bypass.expect(bypass, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        event = decode_event_from_envelope!(body)

        assert event["culprit"] == "Sentry.PlugCaptureTest.PhoenixController.throw/2"
        assert event["message"]["formatted"] == "Uncaught throw - :test"
        Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
      end)

      catch_throw(conn(:get, "/throw_route") |> call_phoenix_endpoint())
    end

    test "does not send Phoenix.Router.NoRouteError" do
      conn(:get, "/not_found")
      |> call_phoenix_endpoint()
    end

    test "scrubs Phoenix.ActionClauseError", %{bypass: bypass} do
      test_pid = self()
      ref = make_ref()

      Bypass.expect(bypass, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {ref, body})
        Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
      end)

      assert_raise Phoenix.ActionClauseError, fn ->
        conn(:get, "/action_clause_error?password=secret")
        |> Plug.Conn.put_req_header("authorization", "yes")
        |> call_phoenix_endpoint()
      end

      assert_receive {^ref, sentry_body}
      event = decode_event_from_envelope!(sentry_body)

      assert event["culprit"] ==
               "Sentry.PlugCaptureTest.PhoenixController.action_clause_error/2"

      assert [exception] = event["exception"]
      assert exception["type"] == "Phoenix.ActionClauseError"
      assert exception["value"] =~ ~s(params: %{"password" => "*********"})
    end

    test "can render feedback form in Phoenix ErrorView", %{bypass: bypass} do
      Bypass.expect(bypass, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        _event = decode_event_from_envelope!(body)

        Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
      end)

      conn = conn(:get, "/error_route")

      assert_raise RuntimeError, "PhoenixError", fn -> call_phoenix_endpoint(conn) end

      {event_id, _} = Sentry.get_last_event_id_and_source()

      assert_received {:plug_conn, :sent}
      assert {500, _headers, body} = sent_resp(conn)
      assert body =~ "sentry-cdn"
      assert body =~ event_id
      assert body =~ ~s{"title":"Testing"}
    end

    test "handles Erlang error in Plug.Conn.WrapperError", %{bypass: bypass} do
      Bypass.expect(bypass, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        event = decode_event_from_envelope!(body)
        assert event["culprit"] == "Sentry.PlugCaptureTest.PhoenixController.assigns/2"
        Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
      end)

      assert_raise KeyError, fn ->
        conn(:get, "/assigns_route")
        |> Plug.Conn.put_req_header("throw", "throw")
        |> call_phoenix_endpoint()
      end
    end

    test "modifies conn with custom scrubber", %{bypass: bypass} do
      Application.put_env(:sentry, PhoenixEndpointWithScrubber,
        render_errors: [view: Sentry.ErrorView, accepts: ~w(html)]
      )

      pid = start_supervised!(PhoenixEndpointWithScrubber)
      Process.link(pid)

      Bypass.expect(bypass, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        event = decode_event_from_envelope!(body)

        assert event["culprit"] == "Sentry.PlugCaptureTest.PhoenixController.error/2"

        assert List.first(event["exception"])["type"] == "RuntimeError"
        assert List.first(event["exception"])["value"] == "PhoenixError"

        Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
      end)

      assert_raise RuntimeError, "PhoenixError", fn ->
        conn(:get, "/error_route")
        |> Plug.run([{PhoenixEndpointWithScrubber, []}])
      end
    end
  end

  defp call_plug_app(conn), do: Plug.run(conn, [{Sentry.ExamplePlugApplication, []}])

  defp call_phoenix_endpoint(conn), do: Plug.run(conn, [{PhoenixEndpoint, []}])

  defp decode_event_from_envelope!(envelope) do
    assert [{%{"type" => "event"}, event}] = decode_envelope!(envelope)
    event
  end
end
