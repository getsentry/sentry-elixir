defmodule Sentry.ClientError do
  @moduledoc """
  An exception struct that represents an error returned by Sentry when
  reporting an error or a message.

  This struct is designed to manage and handle errors originating from operations
  in the Sentry client. The `:reason` field contains the cause of the error
  as an atom or tuple (see `t:reason/0`).

  To raise instances of this exception, you can use `raise/1`. When crafting
  formatted error messages for purposes such as logging or presentation, consider
  leveraging `Exception.message/1`.
  """

  @moduledoc since: "10.7.0"

  @doc """
  The exception struct for a Sentry error.
  """
  defexception [:reason, :http_response]

  @typedoc """
  The type for a Sentry error exception.
  """
  @type t :: %__MODULE__{
          reason: reason(),
          http_response:
            nil | {status :: 100..599, headers :: [{String.t(), String.t()}], body :: binary()}
        }

  @typedoc """
  The reason for a Sentry error exception.
  """
  @type reason() ::
          :too_many_retries
          | :rate_limited
          | :server_error
          | :envelope_too_large
          | {:invalid_json, Exception.t()}
          | {:request_failure, reason :: :inet.posix() | term()}
          | {Exception.kind(), reason :: term(), Exception.stacktrace()}

  @doc false
  @spec new(reason()) :: t
  def new(reason) do
    %__MODULE__{reason: reason}
  end

  @doc false
  @spec server_error(status :: 100..599, headers :: [{String.t(), String.t()}], body :: binary()) ::
          t
  def server_error(status, headers, body) do
    %__MODULE__{reason: :server_error, http_response: {status, headers, body}}
  end

  @doc false
  @spec envelope_too_large(
          status :: 100..599,
          headers :: [{String.t(), String.t()}],
          body :: binary()
        ) :: t
  def envelope_too_large(status, headers, body) do
    %__MODULE__{reason: :envelope_too_large, http_response: {status, headers, body}}
  end

  @impl true
  def message(%__MODULE__{reason: reason, http_response: http_response}) do
    "Sentry failed to report event: #{format(reason, http_response)}"
  end

  defp format(:server_error, {status, headers, body}) do
    """
    the Sentry server responded with an error, the details are below.
    HTTP Status: #{status}
    Response Headers: #{inspect(headers)}
    Response Body: #{inspect(body)}
    """
  end

  defp format(:envelope_too_large, {status, headers, body}) do
    """
    the envelope was rejected due to exceeding size limits.
    HTTP Status: #{status}
    Response Headers: #{inspect(headers)}
    Response Body: #{inspect(body)}
    """
  end

  defp format(reason, nil) do
    format(reason)
  end

  defp format(:too_many_retries) do
    "Sentry responded with status 429 - Too Many Requests and the SDK exhausted the configured retries"
  end

  defp format(:rate_limited) do
    "the event was dropped because the category is currently rate-limited by Sentry"
  end

  defp format({:invalid_json, reason}) do
    formatted =
      if is_exception(reason) do
        Exception.message(reason)
      else
        inspect(reason)
      end

    "the Sentry SDK could not encode the event to JSON: #{formatted}"
  end

  defp format({:request_failure, reason}) do
    "there was a request failure: #{format_request_failure(reason)}"
  end

  defp format({kind, data, stacktrace}) do
    """
    there was an unexpected error:

    #{Exception.format(kind, data, stacktrace)}\
    """
  end

  defp format_request_failure(reason) when is_binary(reason) do
    reason
  end

  defp format_request_failure(reason) when is_atom(reason) do
    case :inet.format_error(reason) do
      ~c"unknown POSIX error" -> inspect(reason)
      formatted -> List.to_string(formatted)
    end
  end

  defp format_request_failure(reason) do
    inspect(reason)
  end
end
