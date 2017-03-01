defmodule Sentry.TestClient do
  def send_event(%Sentry.Event{} = event) do
    {endpoint, _public_key, _secret_key} = Sentry.Client.get_dsn!
    case Poison.encode(event) do
      {:ok, body} ->
        Sentry.Client.request(:post, endpoint, [], body)
      {:error, _error} ->
        :error
    end
  end
end
