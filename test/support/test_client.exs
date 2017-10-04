defmodule Sentry.TestClient do
  @behaviour Sentry.HTTPClient
  require Logger

  def send_event(%Sentry.Event{} = event, _opts \\ []) do
    {endpoint, _public_key, _secret_key} = Sentry.Client.get_dsn()
    event = Sentry.Client.maybe_call_before_send_event(event)

    Sentry.Client.render_event(event)
    |> Poison.encode()
    |> case do
      {:ok, body} ->
        Sentry.Client.request(:post, endpoint, [], body)

      {:error, error} ->
        Logger.error("Error sending in Sentry.TestClient: #{inspect(error)}")
        :error
    end
  end
end
