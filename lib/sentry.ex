defmodule Sentry do
  alias Sentry.{Event, Client}
  require Logger

  @doc """
  Parses and submits an exception to Sentry if current environment is in included_environments.
  """
  @spec capture_logger_message(String.t) :: {:ok, String.t} | :error
  def capture_logger_message(message) do
    Event.transform(message)
    |> send_event()
  end

  @doc """
  Parses and submits an exception to Sentry if current environment is in included_environments.
  """
  @spec capture_exception(Exception.t) :: {:ok, String.t} | :error
  def capture_exception(exception) do
  end

  @spec send_event(%Event{}) :: {:ok, String.t} | :error
  def send_event(%Event{message: nil, exception: nil}) do
    Logger.warn("unable to parse exception")
    {:ok, "Unable to parse as exception, ignoring..."}
  end

  def send_event(event = %Event{}) do
    included_environments = Application.fetch_env!(:sentry, :included_environments)
    if Application.fetch_env!(:sentry, :environment_name) in included_environments do
      quote do
        Client.send_event(unquote(event))
      end
    else
      quote do
        _ = unquote(event)
        {:ok, ""}
      end
    end
  end
end
