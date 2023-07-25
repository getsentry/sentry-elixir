defmodule Sentry.PlugCapture do
  @moduledoc """
  Provides basic functionality to handle and send errors occurring within
  Plug applications, including Phoenix.
  It is intended for usage with `Sentry.PlugContext`.

  #### Usage
  In a Phoenix application, it is important to use this module before
  the Phoenix endpoint itself. It should be added to your endpoint.ex:


      defmodule MyApp.Endpoint
        use Sentry.PlugCapture
        use Phoenix.Endpoint, otp_app: :my_app
        # ...
      end

  In a Plug application, it can be added below your router:

      defmodule MyApp.PlugRouter do
        use Plug.Router
        use Sentry.PlugCapture
        # ...
      end
  """
  defmacro __using__(_opts) do
    quote do
      @before_compile Sentry.PlugCapture
    end
  end

  defmacro __before_compile__(_) do
    quote do
      defoverridable call: 2

      def call(conn, opts) do
        try do
          super(conn, opts)
        rescue
          e in Plug.Conn.WrapperError ->
            exception = Exception.normalize(:error, e.reason, e.stack)
            _ = Sentry.capture_exception(exception, stacktrace: e.stack, event_source: :plug)
            Plug.Conn.WrapperError.reraise(e)

          e ->
            _ = Sentry.capture_exception(e, stacktrace: __STACKTRACE__, event_source: :plug)
            :erlang.raise(:error, e, __STACKTRACE__)
        catch
          kind, reason ->
            message = "Uncaught #{kind} - #{inspect(reason)}"
            stack = __STACKTRACE__
            _ = Sentry.capture_message(message, stacktrace: stack, event_source: :plug)
            :erlang.raise(kind, reason, stack)
        end
      end
    end
  end
end
