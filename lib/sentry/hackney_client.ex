defmodule Sentry.HackneyClient do
  @behaviour Sentry.HTTPClient

  @moduledoc """
  The built-in HTTP client.

  This client implements the `Sentry.HTTPClient` behaviour.

  It's based on the [hackney](https://github.com/benoitc/hackney) Erlang HTTP client,
  which is an *optional dependency* of this library. If you wish to use another
  HTTP client, you'll have to implement your own `Sentry.HTTPClient`. See the
  documentation for `Sentry.HTTPClient` for more information.

  Sentry starts its own hackney pool called `:sentry_pool`. If you need to set other
  [hackney configuration options](https://github.com/benoitc/hackney/blob/master/doc/hackney.md#request5)
  for things such as proxies, using your own pool, or response timeouts, the `:hackney_opts`
  configuration is passed directly to hackney for each request. See the configuration
  documentation in the `Sentry` module.
  """

  @hackney_pool_name :sentry_pool

  @impl true
  def child_spec do
    if Code.ensure_loaded?(:hackney) and Code.ensure_loaded?(:hackney_pool) do
      case Application.ensure_all_started(:hackney) do
        {:ok, _apps} -> :ok
        {:error, reason} -> raise "failed to start the :hackney application: #{inspect(reason)}"
      end

      :hackney_pool.child_spec(
        @hackney_pool_name,
        timeout: Sentry.Config.hackney_timeout(),
        max_connections: Sentry.Config.max_hackney_connections()
      )
    else
      raise """
      cannot start the :sentry application because the HTTP client is set to \
      Sentry.HackneyClient (which is the default), but the Hackney library is not loaded. \
      Add :hackney to your dependencies to fix this.
      """
    end
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
