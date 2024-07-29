defmodule Sentry.FinchClient do
  @behaviour Sentry.HTTPClient

  @moduledoc """
  The built-in HTTP client.

  This client implements the `Sentry.HTTPClient` behaviour.

  It's based on the [finch](https://github.com/sneako/finch) Erlang HTTP client,
  which is an *optional dependency* of this library. If you wish to use another
  HTTP client, you'll have to implement your own `Sentry.HTTPClient`. See the
  documentation for `Sentry.HTTPClient` for more information.

  Finch is built on top of NimblePool. If you need to set other pool configuration options,
  see "Pool Configuration Options" in the source code for details on the possible map values.
  [finch configuration options](https://github.com/sneako/finch/blob/main/lib/finch.ex)
  """
  @impl true
  def child_spec do
    if Code.ensure_loaded?(Finch) do
      case Application.ensure_all_started(:finch) do
        {:ok, _apps} -> :ok
        {:error, reason} -> raise "failed to start the :finch application: #{inspect(reason)}"
      end

      Finch.child_spec(
        name: __MODULE__,
        pools: %{
          :default => [
            size: Sentry.Config.max_finch_connections(),
            conn_max_idle_time: Sentry.Config.finch_timeout()
          ]
        }
      )
    else
      raise """
      cannot start the :sentry application because the HTTP client is set to \
      Sentry.FinchClient (which is the default), but the Finch library is not loaded. \
      Add :finch to your dependencies to fix this.
      """
    end
  end

  @impl true
  def post(url, headers, body) do
    request = Finch.build(:post, url, headers, body)

    case Finch.request(request, __MODULE__) do
      {:ok, %Finch.Response{status: status, headers: headers, body: body}} ->
        {:ok, status, headers, body}

      {:error, error} ->
        {:error, error}
    end
  end
end
