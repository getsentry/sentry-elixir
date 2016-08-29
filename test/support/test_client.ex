defmodule Sentry.TestClient do
  def send_event(%Sentry.Event{} = event) do
    {endpoint, _public_key, _secret_key} = Sentry.Client.parse_dsn!(Application.fetch_env!(:sentry, :dsn))
    body = Poison.encode!(event)
    :hackney.request(:post, endpoint, [], body, [])
  end
end
