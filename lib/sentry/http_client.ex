defmodule Sentry.HTTPClient do
  @moduledoc """
  A behaviour for HTTP clients that Sentry can use.

  The default HTTP client is `Sentry.HackneyClient`.

  To configure a different HTTP client, implement the `Sentry.HTTPClient` behaviour and
  change the `:client` configuration:

      config :sentry,
        client: MyHTTPClient

  """

  @typedoc """
  The response status for an HTTP request.
  """
  @typedoc since: "9.0.0"
  @type status :: 100..599

  @typedoc """
  HTTP request or response headers.
  """
  @type headers :: [{String.t(), String.t()}]

  @typedoc """
  HTTP request or response body.
  """
  @typedoc since: "9.0.0"
  @type body :: binary()

  @doc """
  Should return a **child specification** to start the HTTP client.

  For example, this can start a pool of HTTP connections dedicated to Sentry.
  """
  @callback child_spec() :: :supervisor.child_spec()

  @doc """
  Should make an HTTP `POST` request to `url` with the given `headers` and `body`.
  """
  @callback post(url :: String.t(), request_headers :: headers(), request_body :: body()) ::
              {:ok, status(), response_headers :: headers(), response_body :: body()}
              | {:error, term()}
end
