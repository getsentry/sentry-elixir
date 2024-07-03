defmodule Sentry.ClientErrorTest do
  use Sentry.Case
  alias Sentry.ClientError

  describe "message/1" do
    test "with atom - returns message" do
      assert "request failure reason: Sentry responded with status 429 - Too Many Requests" =
               ClientError.message(%Sentry.ClientError{
                 reason: :too_many_retries
               })
    end

    test "with tuple {:invalid_json, _} - returns message" do
      assert "request failure reason: Invalid JSON -> unexpected byte at position 0: 0x69 (\"i\")" =
               ClientError.message(%Sentry.ClientError{
                 reason:
                   {:invalid_json,
                    %Jason.DecodeError{position: 0, token: nil, data: "invalid JSON"}}
               })
    end

    test "with tuple {:request_failure, _} and binary - returns message" do
      assert "request failure reason: Received 400 from Sentry server: some error" =
               ClientError.message(%Sentry.ClientError{
                 reason: {:request_failure, "Received 400 from Sentry server: some error"}
               })
    end

    test "with tuple {:request_failure, _} and atom - returns message" do
      assert "request failure reason: connection refused" =
               ClientError.message(%Sentry.ClientError{
                 reason: {:request_failure, :econnrefused}
               })
    end

    test "with tuple {:request_failure, _} and anything else - returns message" do
      assert "request failure reason: {:error, %RuntimeError{message: \"I'm a really bad HTTP client\"}}" =
               ClientError.message(%Sentry.ClientError{
                 reason:
                   {:request_failure,
                    {:error, %RuntimeError{message: "I'm a really bad HTTP client"}}}
               })
    end

    test "with Exception- returns message" do
      {kind, data, stacktrace} =
        {:error, %RuntimeError{message: "I'm a really bad HTTP client"}, []}

      assert "request failure reason: Sentry failed to report event due to an unexpected error:\n\n** (RuntimeError) I'm a really bad HTTP client" =
               ClientError.message(%Sentry.ClientError{
                 reason: {kind, data, stacktrace}
               })
    end
  end
end
