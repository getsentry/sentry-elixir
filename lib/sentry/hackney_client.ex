defmodule Sentry.HackneyClient do
  @behaviour Sentry.HTTPClient

  @moduledoc """
  The built-in HTTP client.
  """

  @hackney_pool_name :sentry_pool

  if Application.get_env(:sentry, :client) in [__MODULE__, nil] do
    unless Code.ensure_loaded?(:hackney) do
      raise """
      Sentry.HackneyClient cannot be used as a client because :hackney is not available.
      Please make sure to add hackney as a dependency:

          {:hackney, "~> 1.8"}
      """
    end
  end

  def child_spec do
    Application.ensure_all_started(:hackney)

    :hackney_pool.child_spec(
      @hackney_pool_name,
      timeout: Sentry.Config.hackney_timeout(),
      max_connections: Sentry.Config.max_hackney_connections()
    )
  end

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
