defmodule Sentry.PlugCaptureTest do
  use Sentry.Case
  import Plug.Test

  import Sentry.Test.Assertions

  alias Sentry.Test, as: SentryTest

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

    json_mod = if Code.ensure_loaded?(JSON), do: JSON, else: Jason

    plug Plug.Parsers, parsers: [:json], pass: ["*/*"], json_decoder: json_mod
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

    json_mod = if Code.ensure_loaded?(JSON), do: JSON, else: Jason

    plug Plug.Parsers, parsers: [:json], pass: ["*/*"], json_decoder: json_mod
    plug Sentry.PlugContext
    plug PhoenixRouter
  end

  setup do
    SentryTest.setup_sentry()
  end

  describe "with a Plug application" do
    test "sends error to Sentry and uses Sentry.PlugContext to fill in context" do
      assert_raise(Plug.Conn.WrapperError, "** (RuntimeError) Error", fn ->
        conn(:get, "/error_route")
        |> call_plug_app()
      end)

      assert_sentry_report(:event,
        request: %{
          url: "http://www.example.com/error_route",
          method: "GET",
          query_string: "",
          data: %{}
        }
      )
    end

    test "sends throws to Sentry" do
      catch_throw(conn(:get, "/throw_route") |> call_plug_app())

      assert_sentry_report(:event, [])
    end

    test "sends exits to Sentry" do
      catch_exit(conn(:get, "/exit_route") |> call_plug_app())

      assert_sentry_report(:event, [])
    end

    test "does not send error on unmatched routes", %{bypass: _bypass} do
      assert_raise FunctionClauseError, ~r/no function clause matching/, fn ->
        conn(:get, "/not_found")
        |> call_plug_app()
      end
    end

    test "can render feedback form" do
      conn = conn(:get, "/error_route")

      assert_raise Plug.Conn.WrapperError, "** (RuntimeError) Error", fn ->
        call_plug_app(conn)
      end

      assert_sentry_report(:event, [])

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

    test "reports raised exceptions" do
      assert_raise RuntimeError, "PhoenixError", fn ->
        conn(:get, "/error_route")
        |> call_phoenix_endpoint()
      end

      event =
        assert_sentry_report(:event,
          culprit: "Sentry.PlugCaptureTest.PhoenixController.error/2"
        )

      assert [exception] = event.exception
      assert exception.type == "RuntimeError"
      assert exception.value == "PhoenixError"
    end

    test "reports exits" do
      catch_exit(conn(:get, "/exit_route") |> call_phoenix_endpoint())

      assert_sentry_report(:event,
        culprit: "Sentry.PlugCaptureTest.PhoenixController.exit/2",
        message: %{formatted: "Uncaught exit - :test"}
      )
    end

    test "reports throws" do
      catch_throw(conn(:get, "/throw_route") |> call_phoenix_endpoint())

      assert_sentry_report(:event,
        culprit: "Sentry.PlugCaptureTest.PhoenixController.throw/2",
        message: %{formatted: "Uncaught throw - :test"}
      )
    end

    test "does not send Phoenix.Router.NoRouteError" do
      conn(:get, "/not_found")
      |> call_phoenix_endpoint()
    end

    test "scrubs Phoenix.ActionClauseError" do
      assert_raise Phoenix.ActionClauseError, fn ->
        conn(:get, "/action_clause_error?password=secret")
        |> Plug.Conn.put_req_header("authorization", "yes")
        |> call_phoenix_endpoint()
      end

      event =
        assert_sentry_report(:event,
          culprit: "Sentry.PlugCaptureTest.PhoenixController.action_clause_error/2"
        )

      assert [exception] = event.exception
      assert exception.type == "Phoenix.ActionClauseError"
      assert exception.value =~ ~s(params: %{"password" => "*********"})
    end

    test "can render feedback form in Phoenix ErrorView" do
      conn = conn(:get, "/error_route")

      assert_raise RuntimeError, "PhoenixError", fn -> call_phoenix_endpoint(conn) end

      assert_sentry_report(:event, [])

      {event_id, _} = Sentry.get_last_event_id_and_source()

      assert_received {:plug_conn, :sent}
      assert {500, _headers, body} = sent_resp(conn)
      assert body =~ "sentry-cdn"
      assert body =~ event_id
      assert body =~ ~s{"title":"Testing"}
    end

    test "handles Erlang error in Plug.Conn.WrapperError" do
      assert_raise KeyError, fn ->
        conn(:get, "/assigns_route")
        |> Plug.Conn.put_req_header("throw", "throw")
        |> call_phoenix_endpoint()
      end

      assert_sentry_report(:event,
        culprit: "Sentry.PlugCaptureTest.PhoenixController.assigns/2"
      )
    end

    test "modifies conn with custom scrubber" do
      Application.put_env(:sentry, PhoenixEndpointWithScrubber,
        render_errors: [view: Sentry.ErrorView, accepts: ~w(html)]
      )

      pid = start_supervised!(PhoenixEndpointWithScrubber)
      Process.link(pid)

      assert_raise RuntimeError, "PhoenixError", fn ->
        conn(:get, "/error_route")
        |> Plug.run([{PhoenixEndpointWithScrubber, []}])
      end

      event =
        assert_sentry_report(:event,
          culprit: "Sentry.PlugCaptureTest.PhoenixController.error/2"
        )

      assert [exception] = event.exception
      assert exception.type == "RuntimeError"
      assert exception.value == "PhoenixError"
    end
  end

  defp call_plug_app(conn), do: Plug.run(conn, [{Sentry.ExamplePlugApplication, []}])

  defp call_phoenix_endpoint(conn), do: Plug.run(conn, [{PhoenixEndpoint, []}])
end
