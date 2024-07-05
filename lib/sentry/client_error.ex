defmodule Sentry.ClientError do
  @moduledoc """
  An exception struct that represents an error returned by Sentry when
  reporting an error or a message.

  This struct is designed to manage and handle errors originating from operations
  in the Sentry client. The `:reason` field signifies the cause of the error
  as an atom or tuple.

  To raise instances of this exception, you can use `Kernel.raise/1`. When crafting
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

  @type reason() ::
          :too_many_retries
          | :server_error
          | {:invalid_json, Exception.t()}
          | {:request_failure, String.t()}
          | {:request_failure, atom}
          | {:request_failure, term()}
          | {atom(), term(), [term()]}

  @doc false
  @spec new(reason()) :: t
  def new(reason) do
    %__MODULE__{reason: reason}
  end

  @spec server_error(
          status :: 100..599,
          headers ::
            [{String.t(), String.t()}],
          body :: binary()
        ) :: t
  def server_error(status, headers, body) do
    %__MODULE__{reason: :server_error, http_response: {status, headers, body}}
  end

  @impl true
  def message(%__MODULE__{reason: reason, http_response: http_response})
      when is_nil(http_response) do
    "request failure reason: #{format(reason)}"
  end

  def message(%__MODULE__{reason: reason, http_response: http_response}) do
    "request failure reason: #{format(reason, http_response)}"
  end

  defp format(:too_many_retries) do
    "Sentry responded with status 429 - Too Many Requests"
  end

  defp format({:invalid_json, reason}) do
    "Invalid JSON -> #{Exception.message(reason)}"
  end

  defp format({:request_failure, reason}) when is_binary(reason) do
    "#{reason}"
  end

  defp format({:request_failure, reason}) when is_atom(reason) do
    case :inet.format_error(reason) do
      ~c"unknown POSIX error" -> inspect(reason)
      formatted -> List.to_string(formatted)
    end
  end

  defp format({:request_failure, reason}) do
    inspect(reason)
  end

  defp format({kind, data, stacktrace}) do
    """
    Sentry failed to report event due to an unexpected error:

    #{Exception.format(kind, data, stacktrace)}\
    """
  end

  defp format(:server_error, {status, headers, body}) do
    """
    Sentry failed to report the event due to a server error.
    HTTP Status: #{status}
    Response Headers: #{inspect(headers)}
    Response Body: #{inspect(body)}
    """
  end
end
