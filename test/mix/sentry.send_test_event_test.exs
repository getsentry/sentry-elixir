defmodule Mix.Tasks.Sentry.SendTestEventTest do
  use ExUnit.Case
  import ExUnit.CaptureIO
  import ExUnit.CaptureLog
  import Sentry.TestEnvironmentHelper

  test "prints if environment_name is not in included_environments" do
    modify_env(:sentry, dsn: "http://public:secret@localhost:43/1", included_environments: [])

    assert capture_io(fn ->
             Mix.Tasks.Sentry.SendTestEvent.run([])
           end) == """
           Client configuration:
           server: http://localhost:43/api/1/store/
           public_key: public
           secret_key: secret
           included_environments: []
           current environment_name: :test
           hackney_opts: [recv_timeout: 50]

           :test is not in [] so no test event will be sent
           """
  end

  test "sends event successfully when configured to" do
    bypass = Bypass.open()

    Bypass.expect(bypass, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert body =~ "Testing sending Sentry event"
      assert conn.request_path == "/api/1/store/"
      assert conn.method == "POST"
      Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
    end)

    modify_env(
      :sentry,
      dsn: "http://public:secret@localhost:#{bypass.port}/1"
    )

    assert capture_io(fn ->
             Mix.Tasks.Sentry.SendTestEvent.run([])
           end) == """
           Client configuration:
           server: http://localhost:#{bypass.port}/api/1/store/
           public_key: public
           secret_key: secret
           included_environments: [:test]
           current environment_name: :test
           hackney_opts: [recv_timeout: 50]

           Sending test event...
           Test event sent!  Event ID: 340
           """
  end

  test "handles error when Sentry server is failing" do
    bypass = Bypass.open()

    Bypass.expect(bypass, fn conn ->
      {:ok, _body, conn} = Plug.Conn.read_body(conn)
      Plug.Conn.resp(conn, 500, ~s<{"id": "340"}>)
    end)

    modify_env(:sentry, dsn: "http://public:secret@localhost:#{bypass.port}/1")

    assert capture_log(fn ->
             assert capture_io(fn ->
                      Mix.Tasks.Sentry.SendTestEvent.run([])
                    end) == """
                    Client configuration:
                    server: http://localhost:#{bypass.port}/api/1/store/
                    public_key: public
                    secret_key: secret
                    included_environments: [:test]
                    current environment_name: :test
                    hackney_opts: [recv_timeout: 50]

                    Sending test event...
                    Error sending event: {:request_failure, "Received 500 from Sentry server: "}
                    """
           end) =~ "Failed to send Sentry event"
  end
end
