defmodule Sentry.FinchClient do
  @behaviour Sentry.HTTPClient

  @moduledoc """
  The built-in HTTP client.

  This client implements the `Sentry.HTTPClient` behaviour.

  It's based on the [finch](https://github.com/sneako/finch) Erlang HTTP client,
  which is an *optional dependency* of this library. If you wish to use another
  HTTP client, you'll have to implement your own `Sentry.HTTPClient`. See the
  documentation for `Sentry.HTTPClient` for more information.

  Sentry starts its own finch pool called `:sentry_pool`. If you need to set other
  [hackney configuration options](https://github.com/benoitc/hackney/blob/master/doc/hackney.md#request5)
  for things such as proxies, using your own pool, or response timeouts, the `:hackney_opts`
  configuration is passed directly to hackney for each request. See the configuration
  documentation in the `Sentry` module.
  """

  @finch_pool_name :sentry_pool

  @impl true
  def child_spec do
    if Code.ensure_loaded?(Finch) do
      case Application.ensure_all_started(:finch) do
        {:ok, _apps} ->
          finch_options = [
            name: @finch_pool_name,
            pools: %{
              :default => [
                size: Sentry.Config.max_finch_connections(),
                conn_max_idle_time: Sentry.Config.finch_timeout()
              ]
            }
          ]

          Finch.child_spec(finch_options)

        {:error, reason} ->
          raise "failed to start the :finch application: #{inspect(reason)}"
      end
    else
      raise """
      cannot start the :sentry application because the HTTP client is set to \
      Sentry.FinchClient (which is the default), but the Hackney library is not loaded. \
      Add :hackney to your dependencies to fix this.
      """
    end
  end

  @impl true
  def post(url, headers, body) do
    # IO.inspect([url, headers, body])
    finch_opts =
      Sentry.Config.finch_opts()
      |> Keyword.put_new(:pool, @finch_pool_name)

    request = Finch.build(:post, url, headers, body)

    case Finch.request(request, __MODULE__, finch_opts) do
      {:ok, %Finch.Response{status: status, headers: headers, body: body}} ->
        {:ok, status, headers, body}

      {:error, error} ->
        {:error, error}
    end
  end
end
