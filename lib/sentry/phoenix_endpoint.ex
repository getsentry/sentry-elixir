defmodule Sentry.Phoenix.Endpoint do
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
