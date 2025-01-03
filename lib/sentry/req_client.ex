defmodule Sentry.ReqClient do
  @behaviour Sentry.HTTPClient

  @moduledoc """
  The built-in HTTP client.

  This client implements the `Sentry.HTTPClient` behaviour.

  It's based on the [Req](https://github.com/wojtekmach/req) HTTP client,
  which is an *optional dependency* of this library. If you wish to use another
  HTTP client, you'll have to implement your own `Sentry.HTTPClient`. See the
  documentation for `Sentry.HTTPClient` for more information.
  """

  @impl true
  def post(url, headers, body) do
    opts =
      Sentry.Config.req_opts()
      |> Keyword.put(:decode_body, false)
      |> Keyword.put(:url, url)
      |> Keyword.put(:body, body)

    req =
      Req.new(opts)
      |> Req.merge(headers: headers)

    case Req.post(req) do
      {:ok, %{status: status, headers: headers, body: body}} = result -> {:ok, status, headers, body}
      {:error, _reason} = error -> error
    end
  end
end
