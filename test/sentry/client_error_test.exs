defmodule Sentry.ClientErrorTest do
  use Sentry.Case
  alias Sentry.ClientError

  describe "message/1" do
    test "with atom - returns message" do
      assert "request failure reason: Sentry responded with status 429 - Too Many Requests" =
               result_msg(:too_many_retries)
    end

    test "with tuple {:invalid_json, _} - returns message" do
      assert "request failure reason: Invalid JSON -> unexpected byte at position 0: 0x69 (\"i\")" =
               result_msg(
                 {:invalid_json,
                  %Jason.DecodeError{position: 0, token: nil, data: "invalid JSON"}}
               )
    end

    test "with tuple {:request_failure, _} and binary - returns message" do
      assert "request failure reason: Received 400 from Sentry server: some error" =
               result_msg({:request_failure, "Received 400 from Sentry server: some error"})
    end

    test "with tuple {:request_failure, _} and atom - returns message" do
      assert "request failure reason: connection refused" =
               result_msg({:request_failure, :econnrefused})
    end

    test "with tuple {:request_failure, _} and anything else - returns message" do
      assert "request failure reason: {:error, %RuntimeError{message: \"I'm a really bad HTTP client\"}}" =
               result_msg(
                 {:request_failure,
                  {:error, %RuntimeError{message: "I'm a really bad HTTP client"}}}
               )
    end

    test "with Exception- returns message" do
      {kind, data, stacktrace} =
        {:error, %RuntimeError{message: "I'm a really bad HTTP client"}, []}

      assert "request failure reason: Sentry failed to report event due to an unexpected error:\n\n** (RuntimeError) I'm a really bad HTTP client" =
               result_msg({kind, data, stacktrace})
    end

    test "with server_error- returns message" do
      {status, headers, body} =
        {400, "Rate limiting.", "{}"}

      assert "request failure reason: Sentry failed to report the event due to a server error.\nHTTP Status: 400\nResponse Headers: \"Rate limiting.\"\nResponse Body: \"{}\"\n" =
               ClientError.server_error(status, headers, body) |> ClientError.message()
    end
  end

  defp result_msg(reason) do
    reason |> ClientError.new() |> ClientError.message()
  end
end
