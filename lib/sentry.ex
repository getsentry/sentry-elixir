defmodule Sentry do
  alias Sentry.{Event, Client}

  @doc """
  Parses and submits an exception to Sentry if DSN is setup in application env.
  """
  @spec capture_exception(String.t) :: {:ok, String.t} | :error
  def capture_exception(exception) do
    included_environments = Application.fetch_env!(:sentry, :included_environments)
    if Application.fetch_env!(:sentry, :environment_name) in included_environments do
      quote do
        do_capture_exception(unquote(exception))
      end
    else
      quote do
        _ = unquote(exception)
        {:ok, ""}
      end
    end
  end

  def do_capture_exception(exception) do
    dsn = Application.fetch_env!(:sentry, :dsn)
          |> Client.parse_dsn!

    Event.transform(exception)
    |> capture_exception(dsn)
  end

  @spec capture_exception(%Event{}, Client.parsed_dsn) :: {:ok, String.t} | :error
  def capture_exception(%Event{message: nil, exception: nil}, _) do
    {:ok, "Unable to parse as exception, ignoring..."}
  end

  def capture_exception(event, {endpoint, public_key, private_key}) do
    auth_headers = Client.authorization_headers(public_key, private_key)

    Client.request(:post, endpoint, auth_headers, event)
  end
end
