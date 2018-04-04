defmodule Sentry.PhoenixEndpointTest do
  use ExUnit.Case
  use Plug.Test
  import Sentry.TestEnvironmentHelper

  Application.put_env(
    :sentry,
    __MODULE__.Endpoint,
    render_errors: [view: Sentry.ErrorView, accepts: ~w(html)]
  )

  defmodule Endpoint do
    use Phoenix.Endpoint, otp_app: :sentry
    use Sentry.Phoenix.Endpoint
    plug(:error)
    plug(Sentry.ExampleApp)

    def error(_conn, _opts) do
      raise "EndpointError"
    end
  end

  test "reports errors occurring in Phoenix Endpoint" do
    bypass = Bypass.open()

    Bypass.expect(bypass, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      json = Poison.decode!(body)
      assert json["culprit"] == "Sentry.PhoenixEndpointTest.Endpoint.error/2"
      assert json["message"] == "(RuntimeError) EndpointError"
      Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
    end)

    modify_env(:sentry, dsn: "http://public:secret@localhost:#{bypass.port}/1")
    modify_env(:phoenix, format_encoders: [])
    {:ok, _} = Endpoint.start_link()

    assert_raise RuntimeError, "EndpointError", fn ->
      conn(:get, "/")
      |> Endpoint.call([])
    end
  end
end
