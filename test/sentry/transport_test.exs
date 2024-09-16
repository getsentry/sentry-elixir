defmodule Sentry.TransportTest do
  use Sentry.Case, async: false

  import Sentry.TestHelpers

  alias Sentry.{ClientError, Envelope, Event, HackneyClient, Transport}

  describe "encode_and_post_envelope/2" do
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

      assert {:ok, "123"} = Transport.encode_and_post_envelope(envelope, HackneyClient)
    end

    test "returns an error if the HTTP client returns a badly-typed response" do
      defmodule InvalidHTTPClient do
        def post(_endpoint, _headers, _body) do
          Process.get(:invalid_http_return_value) ||
            raise "missing :invalid_http_return_value from pdict"
        end
      end

      envelope = Envelope.from_event(Event.create_event(message: "Hello 1"))

      for {:ok, status, headers, body} = invalid_return_value <- [
            {:ok, 10000, [], ""},
            {:ok, 200, %{}, ""},
            {:ok, 200, [], :not_a_binary}
          ] do
        Process.put(:invalid_http_return_value, invalid_return_value)

        assert {:request_failure, {:malformed_http_client_response, ^status, ^headers, ^body}} =
                 error(fn ->
                   Transport.encode_and_post_envelope(envelope, InvalidHTTPClient, _retries = [])
                 end)
      end
    after
      Process.delete(:invalid_http_return_value)
      :code.delete(InvalidHTTPClient)
      :code.purge(InvalidHTTPClient)
    end

    test "returns the HTTP client's error if the HTTP client returns one", %{bypass: bypass} do
      envelope = Envelope.from_event(Event.create_event(message: "Hello"))

      Bypass.down(bypass)

      assert {:request_failure, :econnrefused} =
               error(fn ->
                 Transport.encode_and_post_envelope(envelope, HackneyClient, _retries = [])
               end)
    end

    test "returns an error if the response from Sentry is not 200", %{bypass: bypass} do
      envelope = Envelope.from_event(Event.create_event(message: "Hello"))

      Bypass.expect(bypass, "POST", "/api/1/envelope/", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("x-sentry-error", "some error")
        |> Plug.Conn.resp(400, ~s<{}>)
      end)

      {:error, %ClientError{} = error} =
        Transport.encode_and_post_envelope(envelope, HackneyClient, _retries = [])

      assert error.reason == :server_error
      assert {400, headers, "{}"} = error.http_response
      assert :proplists.get_value("x-sentry-error", headers, nil) == "some error"

      assert Exception.message(error) =~
               "the Sentry server responded with an error, the details are below."
    end

    test "returns an error if the HTTP client raises an error when making the request",
         %{bypass: bypass} do
      envelope = Envelope.from_event(Event.create_event(message: "Hello"))

      defmodule RaisingHTTPClient do
        def post(_endpoint, _headers, _body) do
          raise "I'm a really bad HTTP client"
        end
      end

      assert {:error, %RuntimeError{message: "I'm a really bad HTTP client"}, _stacktrace} =
               error(fn ->
                 Transport.encode_and_post_envelope(envelope, RaisingHTTPClient, _retries = [])
               end)
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

      assert {:exit, :through_the_window, _stacktrace} =
               error(fn ->
                 Transport.encode_and_post_envelope(envelope, ExitingHTTPClient, _retries = [])
               end)
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

      assert {:throw, :catch_me_if_you_can, _stacktrace} =
               error(fn ->
                 Transport.encode_and_post_envelope(envelope, ThrowingHTTPClient, _retries = [])
               end)
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

      assert {:error, %RuntimeError{message: "I'm a really bad JSON library"}, _stacktrace} =
               error(fn ->
                 Transport.encode_and_post_envelope(envelope, HackneyClient, _retries = [])
               end)
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

      assert {:request_failure, %Jason.DecodeError{}} =
               error(fn ->
                 Transport.encode_and_post_envelope(envelope, HackneyClient, _retries = [0])
               end)

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

      assert {:ok, "123"} =
               Transport.encode_and_post_envelope(envelope, HackneyClient, _retries = [10, 25])

      assert System.system_time(:millisecond) - start_time >= 35

      assert_received {:request, ^ref}
      assert_received {:request, ^ref}
      assert_received {:request, ^ref}
    end

    test "fails when it exhausts retries and Sentry replies with 429", %{bypass: bypass} do
      envelope = Envelope.from_event(Event.create_event(message: "Hello"))
      test_pid = self()
      ref = make_ref()

      Bypass.expect(bypass, "POST", "/api/1/envelope/", fn conn ->
        send(test_pid, {:request, ref})

        conn
        |> Plug.Conn.put_resp_header("retry-after", "1")
        |> Plug.Conn.resp(429, ~s<{}>)
      end)

      assert :too_many_retries =
               error(fn ->
                 Transport.encode_and_post_envelope(envelope, HackneyClient, _retries = [])
               end)

      assert_received {:request, ^ref}
    end
  end

  defp error(fun) do
    assert {:error, %ClientError{} = error} = fun.()
    assert is_binary(Exception.message(error))
    error.reason
  end
end
