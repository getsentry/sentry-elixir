defmodule Sentry.ClientTest do
  use ExUnit.Case
  import ExUnit.CaptureLog
  import Mox
  import Sentry.TestEnvironmentHelper
  require Logger

  alias Sentry.Client

  doctest Sentry.Client, import: true

  describe "render_event/1" do
    test "transforms structs into maps" do
      event = Sentry.Event.transform_exception(%RuntimeError{message: "foo"}, user: %{id: 1})

      assert %{
               user: %{id: 1},
               exception: [%{type: "RuntimeError", value: "foo"}],
               sdk: %{name: "sentry-elixir"}
             } = Client.render_event(event)
    end
  end

  test "authorization" do
    modify_env(:sentry, dsn: "https://public:secret@app.getsentry.com/1")
    {_endpoint, public_key, private_key} = Client.get_dsn()

    assert Client.authorization_header(public_key, private_key) =~
             ~r/^Sentry sentry_version=5, sentry_client=sentry-elixir\/#{Application.spec(:sentry, :vsn)}, sentry_timestamp=\d{10}, sentry_key=public, sentry_secret=secret$/
  end

  test "authorization without secret" do
    modify_env(:sentry, dsn: "https://public@app.getsentry.com/1")
    {_endpoint, public_key, private_key} = Client.get_dsn()

    assert Client.authorization_header(public_key, private_key) =~
             ~r/^Sentry sentry_version=5, sentry_client=sentry-elixir\/#{Application.spec(:sentry, :vsn)}, sentry_timestamp=\d{10}, sentry_key=public$/
  end

  test "get dsn with default config" do
    modify_env(:sentry, dsn: "https://public:secret@app.getsentry.com/1")

    assert {"https://app.getsentry.com:443/api/1/envelope/", "public", "secret"} =
             Sentry.Client.get_dsn()
  end

  test "errors on bad public keys" do
    modify_env(:sentry, dsn: "https://app.getsentry.com/1")

    assert {:error, :invalid_dsn} = Sentry.Client.get_dsn()
  end

  test "errors on non-integer project_id" do
    modify_env(:sentry, dsn: "https://public:secret@app.getsentry.com/Mitchell")

    assert {:error, :invalid_dsn} = Sentry.Client.get_dsn()
  end

  test "errors on no project_id" do
    modify_env(:sentry, dsn: "https://public:secret@app.getsentry.com")

    assert {:error, :invalid_dsn} = Sentry.Client.get_dsn()
  end

  test "errors on nil dsn" do
    modify_env(:sentry, dsn: nil)

    assert {:error, :invalid_dsn} = Sentry.Client.get_dsn()
  end

  test "errors on atom dsn" do
    modify_env(:sentry, dsn: :error)

    assert {:error, :invalid_dsn} = Sentry.Client.get_dsn()
  end

  test "logs api errors" do
    bypass = Bypass.open()

    Bypass.expect(bypass, fn conn ->
      {:ok, _body, conn} = Plug.Conn.read_body(conn)
      assert conn.request_path == "/api/1/envelope/"
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
      apply(Event, :not_a_function, [])
    rescue
      e ->
        assert capture_log(fn ->
                 Sentry.capture_exception(e)
               end) =~ ~r/400.*Creation of this event was denied due to rate limiting/
    end
  end

  test "errors when attempting to report invalid JSON" do
    modify_env(:sentry, dsn: "http://public:secret@localhost:3000/1")

    unencodable_event =
      []
      |> Sentry.Event.create_event()
      |> Map.replace!(:level, {:a, :b})

    capture_log(fn ->
      assert {:error, {:invalid_json, _}} = Sentry.Client.send_event(unencodable_event)
    end)
  end

  test "calls anonymous before_send_event" do
    bypass = Bypass.open()

    Bypass.expect(bypass, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      event = TestHelpers.decode_event_from_envelope!(body)

      assert event.extra == %{"key" => "value"}
      assert event.user["id"] == 1
      assert length(List.first(event.exception)["stacktrace"]["frames"]) > 0
      Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
    end)

    modify_env(
      :sentry,
      dsn: "http://public:secret@localhost:#{bypass.port}/1",
      before_send_event: fn e ->
        metadata = Map.new(Logger.metadata())
        {user_id, rest_metadata} = Map.pop(metadata, :user_id)
        %{e | extra: Map.merge(e.extra, rest_metadata), user: Map.put(e.user, :id, user_id)}
      end
    )

    Logger.metadata(key: "value", user_id: 1)

    try do
      apply(Event, :not_a_function, [])
    rescue
      e ->
        assert capture_log(fn ->
                 Sentry.capture_exception(e, result: :sync, stacktrace: __STACKTRACE__)
               end)
    end
  end

  test "calls MFA before_send_event" do
    bypass = Bypass.open()

    Bypass.expect(bypass, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      event = TestHelpers.decode_event_from_envelope!(body)

      assert event.extra == %{"key" => "value", "user_id" => 1}
      Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
    end)

    modify_env(
      :sentry,
      dsn: "http://public:secret@localhost:#{bypass.port}/1",
      before_send_event: {Sentry.BeforeSendEventTest, :before_send_event}
    )

    Logger.metadata(key: "value", user_id: 1)

    try do
      apply(Event, :not_a_function, [])
    rescue
      e ->
        assert capture_log(fn ->
                 Sentry.capture_exception(e, result: :sync)
               end)
    end
  end

  test "falsey before_send_event does not send event" do
    modify_env(
      :sentry,
      before_send_event: {Sentry.BeforeSendEventTest, :before_send_event_ignore_arithmetic}
    )

    try do
      :rand.uniform() + "1"
    rescue
      e ->
        capture_log(fn ->
          assert Sentry.capture_exception(e, result: :sync) == :excluded
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
      end
    )

    try do
      apply(Event, :not_a_function, [])
    rescue
      e ->
        assert capture_log(fn ->
                 Sentry.capture_exception(e, result: :sync)
               end) =~ "AFTER_SEND_EVENT"
    end
  end

  test "sends event with sample_rate of 1" do
    bypass = Bypass.open()

    Bypass.expect(bypass, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      event = TestHelpers.decode_event_from_envelope!(body)

      assert Enum.count(List.first(event.exception)["stacktrace"]) > 0

      Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
    end)

    modify_env(
      :sentry,
      dsn: "http://public:secret@localhost:#{bypass.port}/1"
    )

    try do
      apply(Event, :not_a_function, [])
    rescue
      e ->
        {:ok, _} =
          Sentry.capture_exception(
            e,
            stacktrace: __STACKTRACE__,
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
      dsn: "http://public:secret@localhost:#{bypass.port}/1"
    )

    try do
      apply(Event, :not_a_function, [])
    rescue
      e ->
        {:ok, _} = Sentry.capture_exception(e, result: :sync, sample_rate: 1)
        Bypass.down(bypass)
        :unsampled = Sentry.capture_exception(e, result: :sync, sample_rate: 0.0)
    end
  end

  test "logs errors at configured log_level" do
    bypass = Bypass.open()
    pid = self()

    Bypass.expect(bypass, fn conn ->
      {:ok, _body, conn} = Plug.Conn.read_body(conn)
      assert conn.request_path == "/api/1/envelope/"
      assert conn.method == "POST"

      conn =
        conn
        |> Plug.Conn.put_resp_header(
          "X-Sentry-Error",
          "Creation of this event was denied due to various reasons."
        )
        |> Plug.Conn.resp(400, "Something bad happened")

      send(pid, "API called")
      conn
    end)

    modify_env(
      :sentry,
      dsn: "http://public:secret@localhost:#{bypass.port}/1",
      log_level: :error
    )

    assert capture_log(fn ->
             try do
               apply(Event, :not_a_function, [])
             rescue
               e ->
                 assert {:error, {:request_failure, _}} =
                          Sentry.capture_exception(e, stacktrace: __STACKTRACE__, result: :sync)

                 assert_receive "API called"
             end
           end) =~ "[error] Failed to send Sentry event"
  end

  test "logs JSON parsing errors at configured log_level" do
    assert capture_log(fn ->
             Sentry.capture_message("something happened", extra: %{metadata: [keyword: "list"]})
           end) =~ "Failed to send Sentry event. Unable to encode JSON"
  end

  describe "client handles exits/throws/exceptions in adapters" do
    setup :verify_on_exit!

    setup do
      modify_env(:sentry,
        dsn: "http://public:secret@localhost:0/1",
        client: Sentry.HTTPClientMock
      )

      faulty_capture_message = fn failure ->
        expect(Sentry.HTTPClientMock, :post, fn _url, _headers, _body -> failure.() end)
        Sentry.capture_message("all your code are belong to us", result: :sync)
      end

      {:ok, faulty_capture_message: faulty_capture_message}
    end

    test "exits", %{faulty_capture_message: faulty_capture_message} do
      log =
        capture_log(fn ->
          assert {:error, {:request_failure, {:exit, :through_the_window, _stacktrace}}} =
                   faulty_capture_message.(fn -> exit(:through_the_window) end)
        end)

      assert log =~ """
             Failed to send Sentry event. ** (exit) :through_the_window
                 test/client_test.exs:\
             """
    end

    test "throws", %{faulty_capture_message: faulty_capture_message} do
      log =
        capture_log(fn ->
          assert {:error, {:request_failure, {:throw, :catch_me_if_you_can, _stacktrace}}} =
                   faulty_capture_message.(fn -> throw(:catch_me_if_you_can) end)
        end)

      assert log =~ """
             Failed to send Sentry event. ** (throw) :catch_me_if_you_can
                 test/client_test.exs:\
             """
    end

    test "exceptions", %{faulty_capture_message: faulty_capture_message} do
      log =
        capture_log(fn ->
          assert {:error,
                  {:request_failure, {:error, %RuntimeError{message: "oops"}, _stacktrace}}} =
                   faulty_capture_message.(fn -> raise "oops" end)
        end)

      assert log =~ """
             Failed to send Sentry event. ** (RuntimeError) oops
                 test/client_test.exs:\
             """
    end
  end
end
