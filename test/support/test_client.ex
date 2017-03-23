defmodule Sentry.TestClient do
  def send_event(%Sentry.Event{} = event) do
    {endpoint, _public_key, _secret_key} = Sentry.Client.get_dsn!
    event = maybe_call_pre_send_event_function(event)
    case Poison.encode(event) do
      {:ok, body} ->
        Sentry.Client.request(:post, endpoint, [], body)
      {:error, _error} ->
        :error
    end
  end

  defp maybe_call_pre_send_event_function(event) do
    case Application.get_env(:sentry, :before_send_event) do
      function when is_function(function) ->
        function.(event)
      {module, function} ->
        apply(module, function, [event])
      nil ->
        event
      _ ->
        raise ArgumentError, message: ":before_send_event must be an anonymous function or a {Module, Function} tuple"
    end
  end
end
