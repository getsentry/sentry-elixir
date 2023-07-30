defmodule Sentry.HackneyClient do
  @behaviour Sentry.HTTPClient

  @moduledoc """
  The built-in HTTP client.

  This client implements the `Sentry.HTTPClient` behaviour.

  It's based on the [hackney](https://github.com/benoitc/hackney) Erlang HTTP client,
  which is an *optional dependency* of this library. If you wish to use another
  HTTP client, you'll have to implement your own `Sentry.HTTPClient`. See the
  documentation for `Sentry.HTTPClient` for more information.
  """

  @hackney_pool_name :sentry_pool

  @impl true
  def child_spec do
    :hackney_pool.child_spec(
      @hackney_pool_name,
      timeout: Sentry.Config.hackney_timeout(),
      max_connections: Sentry.Config.max_hackney_connections()
    )
  end

  @impl true
  def post(url, headers, body) do
    hackney_opts =
      Sentry.Config.hackney_opts()
      |> Keyword.put_new(:pool, @hackney_pool_name)

    case :hackney.request(:post, url, headers, body, [:with_body] ++ hackney_opts) do
      {:ok, _status, _headers, _body} = result -> result
      {:error, _reason} = error -> error
    end
  end
end
