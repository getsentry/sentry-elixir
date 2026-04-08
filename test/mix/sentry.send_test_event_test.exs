defmodule Mix.Tasks.Sentry.SendTestEventTest do
  use Sentry.Case

  import ExUnit.CaptureIO
  import Sentry.TestHelpers

  setup do
    setup_bypass()
  end

  test "prints if :dsn is not set" do
    put_test_config(dsn: nil, finch_pool_opts: [], environment_name: "some_env")

    output =
      capture_io(fn ->
        Mix.Tasks.Sentry.SendTestEvent.run([])
      end)

    assert output =~ """
           Client configuration:
           current environment_name: "some_env"
           Finch pool options: []
           """

    assert output =~ ~s(Event not sent because the :dsn option is not set)
  end

  test "sends event successfully when configured to", %{bypass: bypass} do
    Bypass.expect(bypass, "POST", "/api/1/envelope/", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert body =~ "Testing sending Sentry event"
      Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
    end)

    put_test_config(
      environment_name: "test",
      finch_pool_opts: []
    )

    output =
      capture_io(fn ->
        Mix.Tasks.Sentry.SendTestEvent.run([])
      end)

    assert output =~ """
           Client configuration:
           server: http://localhost:#{bypass.port}/api/1/envelope/
           public_key: public
           secret_key: secret
           current environment_name: "test"
           Finch pool options: []
           """

    assert output =~ "Sending test event..."
    assert output =~ "Test event sent"
    assert output =~ "Event ID: 340"
  end

  @tag :capture_log
  test "handles error when Sentry server is failing", %{bypass: bypass} do
    Bypass.expect(bypass, "POST", "/api/1/envelope/", fn conn ->
      {:ok, _body, conn} = Plug.Conn.read_body(conn)
      Plug.Conn.resp(conn, 500, ~s<{"id": "340"}>)
    end)

    assert_raise Mix.Error, ~r/Error sending event/, fn ->
      capture_io(fn -> Mix.Tasks.Sentry.SendTestEvent.run([]) end)
    end
  end
end
