defmodule Sentry.HTTPClient do
  @moduledoc """
  A behaviour for HTTP clients that Sentry can use.

  The default HTTP client is `Sentry.HackneyClient`.

  To configure a different HTTP client, implement the `Sentry.HTTPClient` behaviour and
  change the `:client` configuration:

      config :sentry,
        client: MyHTTPClient

  ## Child Spec

  The `c:child_spec/0` callback is a callback that should be used when you want Sentry
  to start the HTTP client *under its supervision tree*. If you want to start your own
  HTTP client under your application's supervision tree, just don't implement the callback
  and Sentry won't do anything to start the client.

  > #### Optional Since v9.0.0 {: .warning}
  >
  > The `c:child_spec/0` callback is optional only since v9.0.0 of Sentry, and was required
  > before.
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
  If not provided, Sentry won't do anything to start your HTTP client. See
  [the module documentation](#module-child-spec) for more info.
  """
  @callback child_spec() :: :supervisor.child_spec()

  @doc """
  Should make an HTTP `POST` request to `url` with the given `headers` and `body`.
  """
  @callback post(url :: String.t(), request_headers :: headers(), request_body :: body()) ::
              {:ok, status(), response_headers :: headers(), response_body :: body()}
              | {:error, term()}

  @optional_callbacks [child_spec: 0]
end
