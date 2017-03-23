defmodule Sentry.ClientTest do
  use ExUnit.Case
  import ExUnit.CaptureLog

  alias Sentry.Client
  @sentry_dsn "https://public:secret@app.getsentry.com/1"

  setup do
    Application.put_env(:sentry, :dsn, @sentry_dsn)
  end

  test "authorization" do
    {_endpoint, public_key, private_key} = Client.get_dsn!
    assert Client.authorization_header(public_key, private_key) =~ ~r/Sentry sentry_version=5, sentry_client=sentry-elixir\/#{Application.spec(:sentry, :vsn)}, sentry_timestamp=\d{10}, sentry_key=public, sentry_secret=secret/
  end

  test "get dsn with default config" do
    assert {"https://app.getsentry.com:443/api/1/store/", "public", "secret"} = Sentry.Client.get_dsn!
  end

  test "get dsn with system config" do
    System.put_env("SYSTEM_KEY", @sentry_dsn)
    Application.put_env(:sentry, :dsn, {:system, "SYSTEM_KEY"})
    assert {"https://app.getsentry.com:443/api/1/store/", "public", "secret"} = Sentry.Client.get_dsn!

    System.delete_env("SYSTEM_KEY")
  end

  test "logs api errors" do
    bypass = Bypass.open
    Bypass.expect bypass, fn conn ->
      {:ok, _body, conn} = Plug.Conn.read_body(conn)
      assert conn.request_path == "/api/1/store/"
      assert conn.method == "POST"
      conn
      |> Plug.Conn.put_resp_header("X-Sentry-Error", "Creation of this event was denied due to rate limiting.")
      |> Plug.Conn.resp(400, "Something bad happened")
    end

    Application.put_env(:sentry, :dsn, "http://public:secret@localhost:#{bypass.port}/1")

    try do
      Event.not_a_function
    rescue
      e ->
        assert capture_log(fn ->
          Sentry.capture_exception(e)
        end) =~ ~r/400.*Creation of this event was denied due to rate limiting/
    end
  end

  test "errors when attempting to report invalid JSON" do
    unencodable_tuple = {:a, :b, :c}
    assert :error = Sentry.capture_message(unencodable_tuple)
  end

  test "calls anonymous pre_event_send_function" do
    bypass = Bypass.open
    Bypass.expect bypass, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request_map = Poison.decode!(body)
      assert request_map["extra"] == %{"key" => "value"}
      assert request_map["user"]["id"] == 1
      Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
    end

    Application.put_env(:sentry, :dsn, "http://public:secret@localhost:#{bypass.port}/1")
    Logger.metadata([key: "value", user_id: 1])

    Application.put_env(:sentry, :pre_event_send_function, fn(e) ->
      metadata = Enum.into(Logger.metadata, %{})
      {user_id, rest_metadata} = Map.pop(metadata, :user_id)
      %{e | extra: Map.merge(e.extra, rest_metadata), user: Map.put(e.user, :id, user_id)}
    end)

    try do
      Event.not_a_function
    rescue
      e ->
        assert capture_log(fn ->
          Sentry.capture_exception(e)
        end)
    end

    Application.delete_env(:sentry, :pre_event_send_function)
  end

  test "calls MFA pre_event_send_function" do
    bypass = Bypass.open
    Bypass.expect bypass, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request_map = Poison.decode!(body)
      assert request_map["extra"] == %{"key" => "value", "user_id" => 1}
      Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
    end

    Application.put_env(:sentry, :dsn, "http://public:secret@localhost:#{bypass.port}/1")
    Logger.metadata([key: "value", user_id: 1])
    Application.put_env(:sentry, :pre_event_send_function, {Sentry.PreEventSendFunctionTest, :pre_event_send_function})

    try do
      Event.not_a_function
    rescue
      e ->
        assert capture_log(fn ->
          Sentry.capture_exception(e)
        end)
    end

    Application.delete_env(:sentry, :pre_event_send_function)
  end
end
