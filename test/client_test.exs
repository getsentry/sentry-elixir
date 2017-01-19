defmodule Sentry.ClientTest do
  use ExUnit.Case
  import ExUnit.CaptureLog

  alias Sentry.Client
  @sentry_dsn "https://public:secret@app.getsentry.com/1"

  test "authorization" do
    {_endpoint, public_key, private_key} = Client.parse_dsn!("https://public:secret@app.getsentry.com/1")
    assert Client.authorization_header(public_key, private_key) =~ ~r/Sentry sentry_version=5, sentry_client=sentry-elixir\/#{Application.spec(:sentry, :vsn)}, sentry_timestamp=\d{10}, sentry_key=public, sentry_secret=secret/
  end

  test "parsing dsn" do
    assert {"https://app.getsentry.com:443/api/1/store/", "public", "secret"} =
      Sentry.Client.parse_dsn!("https://public:secret@app.getsentry.com/1")

    assert {"http://app.getsentry.com:9000/api/1/store/", "public", "secret"} =
      Sentry.Client.parse_dsn!("http://public:secret@app.getsentry.com:9000/1")
  end

  test "fetches default dsn_env" do
    Application.put_env(:sentry, :dsn, @sentry_dsn)
    assert @sentry_dsn == Sentry.Client.dsn_env
  end

  test "fetches system dsn_env" do
    System.put_env("SYSTEM_KEY", @sentry_dsn)
    Application.put_env(:sentry, :dsn, {:system, "SYSTEM_KEY"})
    assert @sentry_dsn == Sentry.Client.dsn_env
  end

  test "logs api errors" do
    bypass = Bypass.open
    Bypass.expect bypass, fn conn ->
      {:ok, _body, conn} = Plug.Conn.read_body(conn)
      assert conn.request_path == "/api/1/store/"
      assert conn.method == "POST"
      Plug.Conn.put_resp_header(conn, "X-Sentry-Error", "Creation of this event was denied due to rate limiting.")
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
end
