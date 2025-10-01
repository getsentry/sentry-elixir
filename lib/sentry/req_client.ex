defmodule Sentry.ReqClient do
  @behaviour Sentry.HTTPClient

  @moduledoc """
  HTTP client for Sentry based on Req.

  This client implements the `Sentry.HTTPClient` behaviour.
  It's based on the [Req](https://github.com/wojtekmach/req) Elixir HTTP client,
  which is an *optional dependency* of this library. If you wish to use another
  HTTP client, you'll have to implement your own `Sentry.HTTPClient`. See the
  documentation for `Sentry.HTTPClient` for more information.
  """

  @impl true
  def post(url, headers, body) do
    case Req.post(url, headers: headers, body: body) do
      {:ok, %{status: status, headers: headers, body: body}} ->
        {:ok, status, headers, body}

      {:error, error} ->
        {:error, error}
    end
  end
end
