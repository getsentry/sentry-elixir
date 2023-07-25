defmodule Sentry.HTTPClient do
  @moduledoc """
  Specifies the API for using a custom HTTP Client.

  The default HTTP client is `Sentry.HackneyClient`

  To configure a different HTTP client, implement the `Sentry.HTTPClient` behaviour and
  change the `:client` configuration:

      config :sentry,
        client: MyHTTPClient
  """

  @type headers :: [{String.t(), String.t()}]

  @callback child_spec() :: :supervisor.child_spec()

  @callback post(url :: String.t(), headers, body :: String.t()) ::
              {:ok, status :: pos_integer, headers, body :: String.t()}
              | {:error, term}
end
