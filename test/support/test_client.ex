defmodule Sentry.TestClient do
  @behaviour Sentry.HTTPClient

  def send_event(%Sentry.Event{} = event, _opts \\ []) do
    {endpoint, _public_key, _secret_key} = Sentry.Client.get_dsn!
    event = Sentry.Client.maybe_call_before_send_event(event)
    case Poison.encode(event) do
      {:ok, body} ->
        Sentry.Client.request(:post, endpoint, [], body)
      {:error, _error} ->
        :error
    end
  end
end
