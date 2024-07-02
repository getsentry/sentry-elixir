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
  defexception [:reason]

  @typedoc """
  The type for a Sentry error exception.
  """
  @type t :: %__MODULE__{reason: reason()}

  @type reason() ::
          :too_many_retries
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

  @impl true
  def message(%__MODULE__{reason: reason}) do
    "request failure reason: #{format(reason)}"
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
end
