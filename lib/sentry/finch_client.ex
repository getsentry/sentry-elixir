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

  @impl true
  def child_spec do
    Supervisor.child_spec(
      {Finch,
       name: __MODULE__,
       pools: %{
         :default => [size: 10]
       }},
      id: __MODULE__
    )
  end

  @impl true
  def post(url, headers, body) do
    request = Finch.build(:post, url, headers, body)

    IO.inspect(request)

    opts = Keyword.put_new([], :pool, :sentry_pool)

    case Finch.request(request, __MODULE__, opts) do
      {:ok, %Finch.Response{status: status, headers: headers, body: body}} ->
        {:ok, status, headers, body}

      {:error, error} ->
        {:error, error}
    end
  end
end
