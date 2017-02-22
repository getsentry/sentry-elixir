defmodule Sentry.TestClient do
  @behaviour Sentry.Client

  def send_event(%Sentry.Event{} = event) do
    {endpoint, _public_key, _secret_key} = Sentry.Client.get_dsn!
    body = Poison.encode!(event)
    Sentry.Client.request(:post, endpoint, [], body)

    Task.async(fn -> nil end)
  end
end
