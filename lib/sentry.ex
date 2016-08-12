defmodule Sentry do
  alias Sentry.{Event, Client}

  @doc """
  Parses and submits an exception to Sentry if current environment is in included_environments.
  """
  @spec capture_logger_message(String.t) :: {:ok, String.t} | :error
  def capture_logger_message(message) do
    included_environments = Application.fetch_env!(:sentry, :included_environments)
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

  def do_capture_logger_message(message) do
    dsn = Application.fetch_env!(:sentry, :dsn)
          |> Client.parse_dsn!

    Event.transform(message)
    |> capture_logger_message(dsn)
  end

  @spec capture_logger_message(%Event{}, Client.parsed_dsn) :: {:ok, String.t} | :error
  def capture_logger_message(%Event{message: nil, exception: nil}, _) do
    {:ok, "Unable to parse as exception, ignoring..."}
  end

  def capture_logger_message(event, {endpoint, public_key, private_key}) do
    auth_headers = Client.authorization_headers(public_key, private_key)

    Client.request(:post, endpoint, auth_headers, event)
  end
end
