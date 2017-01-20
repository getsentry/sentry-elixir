defmodule Sentry.TestClient do
  def send_event(%Sentry.Event{} = event) do
    {endpoint, _public_key, _secret_key} = Sentry.Client.get_dsn!
    body = Poison.encode!(event)
    Sentry.Client.request(:post, endpoint, [], body)
  end
end
