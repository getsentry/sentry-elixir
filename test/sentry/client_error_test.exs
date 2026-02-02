defmodule Sentry.ClientErrorTest do
  use Sentry.Case
  alias Sentry.ClientError

  describe "c:Exception.message/1" do
    test "with an atom reason" do
      assert message_for_reason(:too_many_retries) ==
               "Sentry responded with status 429 - Too Many Requests and the SDK exhausted the configured retries"
    end

    test "with {:invalid_json, _} reason" do
      assert message_for_reason(
               {:invalid_json, %Jason.DecodeError{position: 0, token: nil, data: "invalid JSON"}}
             ) ==
               "the Sentry SDK could not encode the event to JSON: unexpected byte at position 0: 0x69 (\"i\")"
    end

    test "with {:request_failure, reason} reason" do
      assert message_for_reason({:request_failure, "some error"}) ==
               "there was a request failure: some error"

      assert message_for_reason({:request_failure, :econnrefused}) ==
               "there was a request failure: connection refused"

      assert message_for_reason({:request_failure, 123}) == "there was a request failure: 123"
    end

    test "with {kind, reason, stacktrace} reason" do
      {:current_stacktrace, stacktrace} = Process.info(self(), :current_stacktrace)

      assert message_for_reason(
               {:error, %RuntimeError{message: "I'm a really bad HTTP client"}, stacktrace}
             ) =~ """
             there was an unexpected error:

             ** (RuntimeError) I'm a really bad HTTP client
                 (elixir\
             """
    end

    test "with :server_error and HTTP response as the reason" do
      exception = ClientError.server_error(400, [{"X-Foo", "true"}], "{}")

      assert Exception.message(exception) == """
             Sentry failed to report event: the Sentry server responded with an error, the details are below.
             HTTP Status: 400
             Response Headers: [{"X-Foo", "true"}]
             Response Body: "{}"
             """
    end

    test "with :envelope_too_large and HTTP response as the reason" do
      exception =
        ClientError.envelope_too_large(
          413,
          [{"X-Sentry-Error", "envelope too large"}],
          "Payload Too Large"
        )

      assert Exception.message(exception) == """
             Sentry failed to report event: the envelope was rejected due to exceeding size limits.
             HTTP Status: 413
             Response Headers: [{"X-Sentry-Error", "envelope too large"}]
             Response Body: "Payload Too Large"
             """
    end
  end

  defp message_for_reason(reason) do
    assert "Sentry failed to report event: " <> rest =
             reason |> ClientError.new() |> Exception.message()

    rest
  end
end
