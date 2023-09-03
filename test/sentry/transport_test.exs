defmodule Sentry.TransportTest do
  use ExUnit.Case, async: false

  import Sentry.TestEnvironmentHelper

  alias Sentry.{Envelope, Event, Transport}

  describe "post_envelope/2" do
    setup do
      bypass = Bypass.open()
      modify_env(:sentry, dsn: "http://public:secret@localhost:#{bypass.port}/1")
      %{bypass: bypass}
    end

    test "sends a POST request with the right headers and payload", %{bypass: bypass} do
      envelope =
        Envelope.new([
          Event.create_event(message: "Hello 1"),
          Event.create_event(message: "Hello 2"),
          Event.create_event(message: "Hello 3")
        ])

      Bypass.expect_once(bypass, fn conn ->
        assert {:ok, body, conn} = Plug.Conn.read_body(conn)

        assert conn.method == "POST"
        assert conn.request_path == "/api/1/envelope/"

        assert ["sentry-elixir/" <> _] = Plug.Conn.get_req_header(conn, "user-agent")
        assert ["application/octet-stream"] = Plug.Conn.get_req_header(conn, "content-type")
        assert [sentry_auth_header] = Plug.Conn.get_req_header(conn, "x-sentry-auth")

        assert sentry_auth_header =~
                 ~r/^Sentry sentry_version=5, sentry_client=sentry-elixir\/#{Application.spec(:sentry, :vsn)}, sentry_timestamp=\d{10}, sentry_key=public, sentry_secret=secret$/

        assert {:ok, ^body} = Envelope.to_binary(envelope)

        Plug.Conn.resp(conn, 200, ~s<{"id":"123"}>)
      end)

      assert {:ok, "123"} = Transport.post_envelope(envelope)
    end

    test "returns the HTTP client's error if the HTTP client returns one", %{bypass: bypass} do
      envelope = Envelope.new([Event.create_event(message: "Hello")])

      Bypass.down(bypass)

      assert {:error, :econnrefused} = Transport.post_envelope(envelope, _retries = [])
    end

    test "returns an error if the response from Sentry is not 200", %{bypass: bypass} do
      envelope = Envelope.new([Event.create_event(message: "Hello")])

      Bypass.expect(bypass, "POST", "/api/1/envelope/", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("x-sentry-error", "some error")
        |> Plug.Conn.resp(400, ~s<{}>)
      end)

      assert {:error, "Received 400 from Sentry server: some error"} =
               Transport.post_envelope(envelope, _retries = [])
    end

    test "returns an error if the HTTP client raises an error when making the request",
         %{bypass: bypass} do
      envelope = Envelope.new([Event.create_event(message: "Hello")])

      defmodule RaisingHTTPClient do
        def post(_endpoint, _headers, _body) do
          raise "I'm a really bad HTTP client"
        end
      end

      modify_env(:sentry, client: RaisingHTTPClient)

      assert {:error, reason} = Transport.post_envelope(envelope, _retries = [])
      assert {:error, %RuntimeError{} = exception, _stacktrace} = reason
      assert exception.message == "I'm a really bad HTTP client"
    after
      :code.delete(RaisingHTTPClient)
      :code.purge(RaisingHTTPClient)
    end

    test "returns an error if the HTTP client EXITs when making the request",
         %{bypass: bypass} do
      envelope = Envelope.new([Event.create_event(message: "Hello")])

      defmodule ExitingHTTPClient do
        def post(_endpoint, _headers, _body) do
          exit(:through_the_window)
        end
      end

      modify_env(:sentry, client: ExitingHTTPClient)

      assert {:error, reason} = Transport.post_envelope(envelope, _retries = [])
      assert {:exit, :through_the_window, _stacktrace} = reason
    after
      :code.delete(ExitingHTTPClient)
      :code.purge(ExitingHTTPClient)
    end

    test "returns an error if the HTTP client throws when making the request",
         %{bypass: bypass} do
      envelope = Envelope.new([Event.create_event(message: "Hello")])

      defmodule ThrowingHTTPClient do
        def post(_endpoint, _headers, _body) do
          throw(:catch_me_if_you_can)
        end
      end

      modify_env(:sentry, client: ThrowingHTTPClient)

      assert {:error, reason} = Transport.post_envelope(envelope, _retries = [])
      assert {:throw, :catch_me_if_you_can, _stacktrace} = reason
    after
      :code.delete(ThrowingHTTPClient)
      :code.purge(ThrowingHTTPClient)
    end

    test "returns an error if the JSON library crashes when decoding the response",
         %{bypass: bypass} do
      envelope = Envelope.new([Event.create_event(message: "Hello")])

      defmodule CrashingJSONLibrary do
        defdelegate encode(term), to: Jason

        def decode(_body) do
          raise "I'm a really bad JSON library"
        end
      end

      Bypass.expect_once(bypass, "POST", "/api/1/envelope/", fn conn ->
        Plug.Conn.resp(conn, 200, ~s<invalid JSON>)
      end)

      modify_env(:sentry, json_library: CrashingJSONLibrary)

      assert {:error, reason} = Transport.post_envelope(envelope, _retries = [])
      assert {:error, %RuntimeError{} = exception, _stacktrace} = reason
      assert exception.message == "I'm a really bad JSON library"
    after
      :code.delete(CrashingJSONLibrary)
      :code.purge(CrashingJSONLibrary)
    end

    test "returns an error if the response from Sentry is not valid JSON, and retries",
         %{bypass: bypass} do
      envelope = Envelope.new([Event.create_event(message: "Hello")])
      test_pid = self()
      ref = make_ref()

      Bypass.expect(bypass, "POST", "/api/1/envelope/", fn conn ->
        send(test_pid, {:request, ref})
        Plug.Conn.resp(conn, 200, ~s<invalid JSON>)
      end)

      assert {:error, %Jason.DecodeError{}} = Transport.post_envelope(envelope, _retries = [0])

      assert_received {:request, ^ref}
      assert_received {:request, ^ref}
    end

    test "supports a list of retries", %{bypass: bypass} do
      envelope = Envelope.new([Event.create_event(message: "Hello")])
      test_pid = self()
      ref = make_ref()
      counter = :counters.new(1, [])

      start_time = System.system_time(:millisecond)

      Bypass.expect(bypass, "POST", "/api/1/envelope/", fn conn ->
        send(test_pid, {:request, ref})

        if :counters.get(counter, 1) < 2 do
          :counters.add(counter, 1, 1)
          Plug.Conn.resp(conn, 503, ~s<{}}>)
        else
          Plug.Conn.resp(conn, 200, ~s<{"id": "123"}>)
        end
      end)

      assert {:ok, "123"} = Transport.post_envelope(envelope, _retries = [10, 25])

      assert System.system_time(:millisecond) - start_time >= 35

      assert_received {:request, ^ref}
      assert_received {:request, ^ref}
      assert_received {:request, ^ref}
    end
  end

  describe "get_dsn/0" do
    test "parses correct DSNs" do
      modify_env(:sentry, dsn: "http://public:secret@localhost:3000/1")
      assert {"http://localhost:3000/api/1/envelope/", "public", "secret"} = Transport.get_dsn()
    end

    test "errors on bad public keys" do
      modify_env(:sentry, dsn: "https://app.getsentry.com/1")
      assert {:error, :invalid_dsn} = Transport.get_dsn()
    end

    test "errors on non-integer project_id" do
      modify_env(:sentry, dsn: "https://public:secret@app.getsentry.com/Mitchell")
      assert {:error, :invalid_dsn} = Transport.get_dsn()
    end

    test "errors on no project_id" do
      modify_env(:sentry, dsn: "https://public:secret@app.getsentry.com")
      assert {:error, :invalid_dsn} = Transport.get_dsn()
    end

    test "errors on nil dsn" do
      modify_env(:sentry, dsn: nil)
      assert {:error, :invalid_dsn} = Transport.get_dsn()
    end

    test "errors on atom dsn" do
      modify_env(:sentry, dsn: :error)
      assert {:error, :invalid_dsn} = Transport.get_dsn()
    end
  end
end
