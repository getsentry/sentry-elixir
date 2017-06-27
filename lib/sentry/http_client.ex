defmodule Sentry.HTTPClient do
  @moduledoc """
  Specifies the API for using a custom HTTP Client.

  Clients must implement the `send_event/1` function that receives
  the Event and sends it to the Sentry API.  It may return anything.

  See `Sentry.Client` for `Sentry.TestClient` for example implementations.
  """

  @callback send_event(Sentry.Event.t, keyword()) :: any
end
