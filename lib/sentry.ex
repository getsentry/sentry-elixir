defmodule Sentry do
  alias Sentry.{Event, Client}
  require Logger

  @doc """
  Parses and submits an exception to Sentry if current environment is in included_environments.
  """
  @spec capture_logger_message(String.t) :: {:ok, String.t} | :error
  def capture_logger_message(message) do
    included_environments = Application.fetch_env!(:sentry, :included_environments)
    do_capture_logger_message(message)
    if Application.fetch_env!(:sentry, :environment_name) in included_environments do
      quote do
        do_capture_logger_message(unquote(message))
      end
    else
      quote do
        _ = unquote(message)
        {:ok, ""}
      end
    end
  end

  @spec do_capture_logger_message(String.t) :: {:ok, String.t} | :error
  def do_capture_logger_message(message) do
    Event.transform(message)
    |> send_event()
  end

  @spec send_event(%Event{}) :: {:ok, String.t} | :error
  def send_event(%Event{message: nil, exception: nil}) do
    Logger.warn("unable to parse exception")
    {:ok, "Unable to parse as exception, ignoring..."}
  end

  def send_event(event = %Event{}) do
    Client.send_event(event)
  end
end
