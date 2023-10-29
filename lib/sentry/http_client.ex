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

  ## Alternative Clients

  Let's look at an example of using an alternative HTTP client. In this example, we'll
  use [Finch](https://github.com/sneako/finch), a lightweight HTTP client for Elixir.

  First, we need to add Finch to our dependencies:

      # In mix.exs
      defp deps do
        [
          # ...
          {:finch, "~> 0.16"}
        ]
      end

  Then, we need to define a module that implements the `Sentry.HTTPClient` behaviour:

      defmodule MyApp.SentryFinchHTTPClient do
        @behaviour Sentry.HTTPClient

        @impl true
        def child_spec do
          Supervisor.child_spec({Finch, name: __MODULE__}, id: __MODULE__)
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

  Last, we need to configure Sentry to use our new HTTP client:

      config :sentry,
        client: MyApp.SentryFinchHTTPClient

  ### Umbrella Apps

  The HTTP client for Sentry is configured globally for the `:sentry` application. In an
  umbrella setup, this means that all applications must configure Sentry to use the same
  HTTP client.

  If you want to use an alternative Sentry HTTP client in your umbrella application, we
  recommend to do this:

    1. Create a new application in the umbrella (we'll call it `sentry_http_client`).

    1. Add `:sentry` as a dependency of the new application.

    1. Add a new module to the new application (such as `SentryHTTPClient`) which implements
       the desired `Sentry.HTTPClient` behaviour.

    1. Configure `:sentry` to use the "shared" HTTP client. This works because configuration
       in umbrella apps is generally shared by all apps within the umbrella (and it's in
       `config/config.exs` at the root of the umbrella).

           config :sentry,
             # ...
             client: SentryHTTPClient

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
