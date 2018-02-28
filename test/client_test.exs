defmodule Sentry.ClientTest do
  use ExUnit.Case
  import ExUnit.CaptureLog
  import Sentry.TestEnvironmentHelper
  require Logger

  alias Sentry.Client

  test "authorization" do
    modify_env(:sentry, dsn: "https://public:secret@app.getsentry.com/1")
    {_endpoint, public_key, private_key} = Client.get_dsn()

    assert Client.authorization_header(public_key, private_key) =~
             ~r/^Sentry sentry_version=5, sentry_client=sentry-elixir\/#{
               Application.spec(:sentry, :vsn)
             }, sentry_timestamp=\d{10}, sentry_key=public, sentry_secret=secret$/
  end

  test "get dsn with default config" do
    modify_env(:sentry, dsn: "https://public:secret@app.getsentry.com/1")

    assert {"https://app.getsentry.com:443/api/1/store/", "public", "secret"} =
             Sentry.Client.get_dsn()
  end

  test "get dsn with system config" do
    modify_env(:sentry, dsn: {:system, "SYSTEM_KEY"})
    modify_system_env(%{"SYSTEM_KEY" => "https://public:secret@app.getsentry.com/1"})

    assert {"https://app.getsentry.com:443/api/1/store/", "public", "secret"} =
             Sentry.Client.get_dsn()
  end

  test "errors on bad public/secret keys" do
    modify_env(:sentry, dsn: "https://public@app.getsentry.com/1")

    capture_log(fn ->
      assert :error = Sentry.Client.get_dsn()
    end)
  end

  test "errors on non-integer project_id" do
    modify_env(:sentry, dsn: "https://public:secret@app.getsentry.com/Mitchell")

    capture_log(fn ->
      assert :error = Sentry.Client.get_dsn()
    end)
  end

  test "errors on no project_id" do
    modify_env(:sentry, dsn: "https://public:secret@app.getsentry.com")

    capture_log(fn ->
      assert :error = Sentry.Client.get_dsn()
    end)
  end

  test "logs api errors" do
    bypass = Bypass.open()

    Bypass.expect(bypass, fn conn ->
      {:ok, _body, conn} = Plug.Conn.read_body(conn)
      assert conn.request_path == "/api/1/store/"
      assert conn.method == "POST"

      conn
      |> Plug.Conn.put_resp_header(
        "X-Sentry-Error",
        "Creation of this event was denied due to rate limiting."
      )
      |> Plug.Conn.resp(400, "Something bad happened")
    end)

    modify_env(:sentry, dsn: "http://public:secret@localhost:#{bypass.port}/1")

    try do
      Event.not_a_function()
    rescue
      e ->
        assert capture_log(fn ->
                 Sentry.capture_exception(e)
               end) =~ ~r/400.*Creation of this event was denied due to rate limiting/
    end
  end

  test "errors when attempting to report invalid JSON" do
    modify_env(:sentry, dsn: "http://public:secret@localhost:3000/1")
    unencodable_tuple = {:a, :b, :c}

    capture_log(fn ->
      assert :error = Sentry.capture_message(unencodable_tuple)
    end)
  end

  test "calls anonymous before_send_event" do
    bypass = Bypass.open()

    Bypass.expect(bypass, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request_map = Poison.decode!(body)
      assert request_map["extra"] == %{"key" => "value"}
      assert request_map["user"]["id"] == 1
      assert is_nil(request_map["stacktrace"]["frames"])
      Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
    end)

    modify_env(
      :sentry,
      dsn: "http://public:secret@localhost:#{bypass.port}/1",
      before_send_event: fn e ->
        metadata = Map.new(Logger.metadata())
        {user_id, rest_metadata} = Map.pop(metadata, :user_id)
        %{e | extra: Map.merge(e.extra, rest_metadata), user: Map.put(e.user, :id, user_id)}
      end,
      client: Sentry.Client
    )

    Logger.metadata(key: "value", user_id: 1)

    try do
      Event.not_a_function()
    rescue
      e ->
        assert capture_log(fn ->
                 Sentry.capture_exception(e, result: :sync)
               end)
    end
  end

  test "calls MFA before_send_event" do
    bypass = Bypass.open()

    Bypass.expect(bypass, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request_map = Poison.decode!(body)
      assert request_map["extra"] == %{"key" => "value", "user_id" => 1}
      Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
    end)

    modify_env(
      :sentry,
      dsn: "http://public:secret@localhost:#{bypass.port}/1",
      before_send_event: {Sentry.BeforeSendEventTest, :before_send_event},
      client: Sentry.Client
    )

    Logger.metadata(key: "value", user_id: 1)

    try do
      Event.not_a_function()
    rescue
      e ->
        assert capture_log(fn ->
                 Sentry.capture_exception(e, result: :sync)
               end)
    end
  end

  test "calls anonymous after_send_event synchronously" do
    bypass = Bypass.open()

    Bypass.expect(bypass, fn conn ->
      {:ok, _body, conn} = Plug.Conn.read_body(conn)
      Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
    end)

    modify_env(
      :sentry,
      dsn: "http://public:secret@localhost:#{bypass.port}/1",
      after_send_event: fn _e, _r ->
        Logger.error("AFTER_SEND_EVENT")
      end,
      client: Sentry.Client
    )

    try do
      Event.not_a_function()
    rescue
      e ->
        assert capture_log(fn ->
                 Sentry.capture_exception(e, result: :sync)
               end) =~ "AFTER_SEND_EVENT"
    end
  end

  test "calls anonymous after_send_event asynchronously" do
    bypass = Bypass.open()

    Bypass.expect(bypass, fn conn ->
      {:ok, _body, conn} = Plug.Conn.read_body(conn)
      Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
    end)

    modify_env(
      :sentry,
      dsn: "http://public:secret@localhost:#{bypass.port}/1",
      after_send_event: fn _e, _r ->
        Logger.error("AFTER_SEND_EVENT")
      end,
      client: Sentry.Client
    )

    try do
      Event.not_a_function()
    rescue
      e ->
        assert capture_log(fn ->
                 {:ok, task} = Sentry.capture_exception(e, result: :async)
                 Task.await(task)
               end) =~ "AFTER_SEND_EVENT"
    end
  end

  test "sends event with sample_rate of 1" do
    bypass = Bypass.open()

    Bypass.expect(bypass, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request_map = Poison.decode!(body)
      assert Enum.count(request_map["stacktrace"]["frames"]) > 0
      Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
    end)

    modify_env(
      :sentry,
      dsn: "http://public:secret@localhost:#{bypass.port}/1",
      client: Sentry.Client
    )

    try do
      Event.not_a_function()
    rescue
      e ->
        {:ok, _} =
          Sentry.capture_exception(
            e,
            stacktrace: System.stacktrace(),
            result: :sync,
            sample_rate: 1
          )
    end
  end

  test "does not send event with sample_rate of 0" do
    bypass = Bypass.open()

    Bypass.expect(bypass, fn conn ->
      {:ok, _body, conn} = Plug.Conn.read_body(conn)
      Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
    end)

    modify_env(
      :sentry,
      dsn: "http://public:secret@localhost:#{bypass.port}/1",
      client: Sentry.Client
    )

    try do
      Event.not_a_function()
    rescue
      e ->
        {:ok, _} = Sentry.capture_exception(e, result: :sync, sample_rate: 1)
        Bypass.down(bypass)
        :unsampled = Sentry.capture_exception(e, result: :sync, sample_rate: 0.0)
    end
  end
end
