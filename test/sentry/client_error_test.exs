defmodule Sentry.ClientErrorTest do
  use Sentry.Case
  alias Sentry.ClientError

  describe "message/1" do
    test "With atom - returns message " do
      assert "Request failure reason: unknown POSIX error: too_many_retries" =
               ClientError.message(%Sentry.ClientError{
                 reason: {:request_failure, :too_many_retries}
               })
    end

    test "With tuple {:invalid_json, _} - returns message " do
      assert "Request failure reason: Invalid JSON -> %Jason.DecodeError{position: 0, token: nil, data: \"invalid JSON\"}" =
               ClientError.message(%Sentry.ClientError{
                 reason:
                   {:invalid_json,
                    %Jason.DecodeError{position: 0, token: nil, data: "invalid JSON"}}
               })
    end

    test "With tuple {:request_failure, _} and binary - returns message " do
      assert "Request failure reason: Received 400 from Sentry server: some error" =
               ClientError.message(%Sentry.ClientError{
                 reason: {:request_failure, "Received 400 from Sentry server: some error"}
               })
    end

    test "With tuple {:request_failure, _} and atom - returns message " do
      assert "Request failure reason: connection refused" =
               ClientError.message(%Sentry.ClientError{
                 reason: {:request_failure, :econnrefused}
               })
    end

    test "With tuple {:request_failure, _} and anything else - returns message " do
      assert "Request failure reason: {:error, %RuntimeError{message: \"I'm a really bad HTTP client\"}}" =
               ClientError.message(%Sentry.ClientError{
                 reason:
                   {:request_failure,
                    {:error, %RuntimeError{message: "I'm a really bad HTTP client"}}}
               })
    end

    test "With Exception- returns message " do
      {kind, data, stacktrace} =
        {:error, "some data for error", "long stacktrace to show where error originated"}

      assert "Request failure reason: Exception: :error with data: \"some data for error\" and stacktrace: \"long stacktrace to show where error originated\"" =
               ClientError.message(%Sentry.ClientError{
                 reason: {kind, data, stacktrace}
               })
    end
  end
end
