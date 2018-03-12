defmodule Sentry.Phoenix.Endpoint do
  @moduledoc """
  Provides basic functionality to handle errors in a Phoenix Endpoint. Errors occurring within a Phoenix request before it reaches the Router will not be captured by `Sentry.Plug` due to the internal workings of Phoenix.

  For more information, see https://github.com/getsentry/sentry-elixir/issues/229.


  #### Usage

  Add the following to your endpoint.ex, below `use Phoenix.Endpoint, otp_app: :my_app`

        use Sentry.Phoenix.Endpoint

  """
  defmacro __using__(_opts) do
    quote do
      @before_compile Sentry.Phoenix.Endpoint
    end
  end

  defmacro __before_compile__(_) do
    quote do
      defoverridable call: 2

      def call(conn, opts) do
        try do
          super(conn, opts)
        catch
          kind, reason ->
            stacktrace = System.stacktrace()
            request = Sentry.Plug.build_request_interface_data(conn, [])
            exception = Exception.normalize(kind, reason, stacktrace)

            Sentry.capture_exception(
              exception,
              stacktrace: stacktrace,
              request: request,
              event_source: :endpoint,
              error_type: kind
            )

            :erlang.raise(kind, reason, stacktrace)
        end
      end
    end
  end
end
