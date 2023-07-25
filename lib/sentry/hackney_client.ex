defmodule Sentry.HackneyClient do
  @behaviour Sentry.HTTPClient

  @moduledoc """
  The built-in HTTP client.
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

    with {:ok, status, headers, client} <-
           :hackney.request(:post, url, headers, body, hackney_opts),
         {:ok, body} <- :hackney.body(client) do
      {:ok, status, headers, body}
    end
  end
end
