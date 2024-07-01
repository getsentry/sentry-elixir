defmodule Sentry.ClientError do
  @moduledoc """
  An exception struct that represents an error returned by Sentry.

  This struct is designed to manage and handle errors originating from operations
  in the client application. The `:reason` field signifies the cause of the error
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
  @type t() :: %__MODULE__{reason: term}

  @doc false
  @spec new(term) :: t
  def new(reason) do
    %__MODULE__{reason: reason}
  end

  @impl true
  def message(%__MODULE__{reason: reason}) do
    "Request failure reason: #{format(reason)}"
  end

  defp format(:too_many_retries) do
    "Sentry responded with status 429 - Too Many Requests"
  end

  defp format({:invalid_json, reason}) do
    "Invalid JSON -> #{inspect(reason)}"
  end

  defp format({:request_failure, reason}) when is_binary(reason) do
    "#{reason}"
  end

  defp format({:request_failure, reason}) when is_atom(reason) do
    lookup_reason =
      case :inet.format_error(reason) do
        ~c"unknown POSIX error" -> inspect(reason)
        formatted -> List.to_string(formatted)
      end

    "#{lookup_reason}"
  end

  defp format({:request_failure, reason}) do
    "#{inspect(reason)}"
  end

  defp format({kind, data, stacktrace}) do
    "Exception: #{inspect(kind)} with data: #{inspect(data)} and stacktrace: #{inspect(stacktrace)}"
  end
end
