defmodule Sentry.TransportTest do
  use Sentry.Case, async: false

  import Sentry.TestHelpers

  alias Sentry.{Envelope, Event, HackneyClient, Transport}

  describe "post_envelope/2" do
    setup do
      bypass = Bypass.open()
      put_test_config(dsn: "http://public:secret@localhost:#{bypass.port}/1")
      %{bypass: bypass}
    end

    test "sends a POST request with the right headers and payload", %{bypass: bypass} do
      envelope = Envelope.from_event(Event.create_event(message: "Hello 1"))

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

      assert {:ok, "123"} = Transport.post_envelope(envelope, HackneyClient)
    end

    test "returns the HTTP client's error if the HTTP client returns one", %{bypass: bypass} do
      envelope = Envelope.from_event(Event.create_event(message: "Hello"))

      Bypass.down(bypass)

      assert {:error, {:request_failure, :econnrefused}} =
               Transport.post_envelope(envelope, HackneyClient, _retries = [])
    end

    test "returns an error if the response from Sentry is not 200", %{bypass: bypass} do
      envelope = Envelope.from_event(Event.create_event(message: "Hello"))

      Bypass.expect(bypass, "POST", "/api/1/envelope/", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("x-sentry-error", "some error")
        |> Plug.Conn.resp(400, ~s<{}>)
      end)

      assert {:error, {:request_failure, "Received 400 from Sentry server: some error"}} =
               Transport.post_envelope(envelope, HackneyClient, _retries = [])
    end

    test "returns an error if the HTTP client raises an error when making the request",
         %{bypass: bypass} do
      envelope = Envelope.from_event(Event.create_event(message: "Hello"))

      defmodule RaisingHTTPClient do
        def post(_endpoint, _headers, _body) do
          raise "I'm a really bad HTTP client"
        end
      end

      assert {:error, {:request_failure, reason}} =
               Transport.post_envelope(envelope, RaisingHTTPClient, _retries = [])

      assert {:error, %RuntimeError{} = exception, _stacktrace} = reason
      assert exception.message == "I'm a really bad HTTP client"
    after
      :code.delete(RaisingHTTPClient)
      :code.purge(RaisingHTTPClient)
    end

    test "returns an error if the HTTP client EXITs when making the request",
         %{bypass: bypass} do
      envelope = Envelope.from_event(Event.create_event(message: "Hello"))

      defmodule ExitingHTTPClient do
        def post(_endpoint, _headers, _body) do
          exit(:through_the_window)
        end
      end

      assert {:error, {:request_failure, reason}} =
               Transport.post_envelope(envelope, ExitingHTTPClient, _retries = [])

      assert {:exit, :through_the_window, _stacktrace} = reason
    after
      :code.delete(ExitingHTTPClient)
      :code.purge(ExitingHTTPClient)
    end

    test "returns an error if the HTTP client throws when making the request",
         %{bypass: bypass} do
      envelope = Envelope.from_event(Event.create_event(message: "Hello"))

      defmodule ThrowingHTTPClient do
        def post(_endpoint, _headers, _body) do
          throw(:catch_me_if_you_can)
        end
      end

      assert {:error, {:request_failure, reason}} =
               Transport.post_envelope(envelope, ThrowingHTTPClient, _retries = [])

      assert {:throw, :catch_me_if_you_can, _stacktrace} = reason
    after
      :code.delete(ThrowingHTTPClient)
      :code.purge(ThrowingHTTPClient)
    end

    test "returns an error if the JSON library crashes when decoding the response",
         %{bypass: bypass} do
      envelope = Envelope.from_event(Event.create_event(message: "Hello"))

      defmodule CrashingJSONLibrary do
        defdelegate encode(term), to: Jason

        def decode("{}"), do: {:ok, %{}}
        def decode(_body), do: raise("I'm a really bad JSON library")
      end

      Bypass.expect_once(bypass, "POST", "/api/1/envelope/", fn conn ->
        Plug.Conn.resp(conn, 200, ~s<invalid JSON>)
      end)

      put_test_config(json_library: CrashingJSONLibrary)

      assert {:error, {:request_failure, reason}} =
               Transport.post_envelope(envelope, HackneyClient, _retries = [])

      assert {:error, %RuntimeError{} = exception, _stacktrace} = reason
      assert exception.message == "I'm a really bad JSON library"
    after
      :code.delete(CrashingJSONLibrary)
      :code.purge(CrashingJSONLibrary)
    end

    test "returns an error if the response from Sentry is not valid JSON, and retries",
         %{bypass: bypass} do
      envelope = Envelope.from_event(Event.create_event(message: "Hello"))
      test_pid = self()
      ref = make_ref()

      Bypass.expect(bypass, "POST", "/api/1/envelope/", fn conn ->
        send(test_pid, {:request, ref})
        Plug.Conn.resp(conn, 200, ~s<invalid JSON>)
      end)

      assert {:error, {:request_failure, %Jason.DecodeError{}}} =
               Transport.post_envelope(envelope, HackneyClient, _retries = [0])

      assert_received {:request, ^ref}
      assert_received {:request, ^ref}
    end

    test "supports a list of retries", %{bypass: bypass} do
      envelope = Envelope.from_event(Event.create_event(message: "Hello"))
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

      assert {:ok, "123"} = Transport.post_envelope(envelope, HackneyClient, _retries = [10, 25])

      assert System.system_time(:millisecond) - start_time >= 35

      assert_received {:request, ^ref}
      assert_received {:request, ^ref}
      assert_received {:request, ^ref}
    end
  end
end
