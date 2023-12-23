defmodule Sentry.PlugCapture do
  @moduledoc """
  Provides basic functionality to capture and send errors occurring within
  Plug applications, including Phoenix.

  It is intended for usage with `Sentry.PlugContext`, which adds relevant request
  metadata to the Sentry context before errors are captured.

  ## Usage

  ### With Phoenix

  In a Phoenix application, it is important to use this module **before**
  the Phoenix endpoint itself. It should be added to your `endpoint.ex` file:

      defmodule MyApp.Endpoint
        use Sentry.PlugCapture
        use Phoenix.Endpoint, otp_app: :my_app

        # ...
      end

  ### With Plug

  In a Plug application, you can add this module *below* your router:

      defmodule MyApp.PlugRouter do
        use Plug.Router
        use Sentry.PlugCapture

        # ...
      end

  > #### `use Sentry.PlugCapture` {: .info}
  >
  > When you `use Sentry.PlugCapture`, Sentry overrides your `c:Plug.call/2` callback
  > and adds capturing errors and reporting to Sentry. You can still re-override
  > that callback after `use Sentry.PlugCapture` if you need to.

  ## Scrubbing Sensitive Data

  > #### Since v9.1.0 {: .neutral}
  >
  > Scrubbing sensitive data in `Sentry.PlugCapture` is available since v9.1.0
  > of this library.

  Like `Sentry.PlugContext`, this module also supports scrubbing sensitive data
  out of errors. However, this module has to do some *guessing* to figure
  out if there are `Plug.Conn` structs to scrub. Right now, the strategy we
  use follows these steps:

    1. if the error is `Phoenix.ActionClauseError`, we scrub the `Plug.Conn` structs
      from the `args` field of that exception

  Otherwise, we don't perform any scrubbing. To configure scrubbing, you can use the
  `:scrubbing` option (see below).

  ## Options

    * `:scrubber` (since v9.1.0) - a term of type `{module, function, args}` that
      will be invoked to scrub sensitive data from `Plug.Conn` structs. The
      `Plug.Conn` struct is prepended to `args` before invoking the function,
      so that the final function will be called as `apply(module, function, [conn | args])`.
      The function must return a `Plug.Conn` struct. By default, the built-in
      scrubber does this:

      * scrubs *all* cookies
      * scrubs sensitive headers just like `Sentry.PlugContext.default_header_scrubber/1`
      * scrubs sensitive body params just like `Sentry.PlugContext.default_body_scrubber/1`

  """

  defmacro __using__(opts) do
    quote do
      opts = unquote(opts)
      default_scrubber = {unquote(__MODULE__), :default_scrubber, []}

      scrubber =
        case Keyword.get(opts, :scrubber, default_scrubber) do
          {mod, fun, args} = scrubber when is_atom(mod) and is_atom(fun) and is_list(args) ->
            scrubber

          other ->
            raise ArgumentError,
                  "expected :scrubber to be a {module, function, args} tuple, got: #{inspect(other)}"
        end

      @__sentry_scrubber scrubber

      @before_compile Sentry.PlugCapture
    end
  end

  defmacro __before_compile__(_env) do
    quote do
      defoverridable call: 2

      def call(conn, opts) do
        try do
          super(conn, opts)
        rescue
          err in Plug.Conn.WrapperError ->
            exception = Exception.normalize(:error, err.reason, err.stack)

            :ok =
              Sentry.PlugCapture.__capture_exception__(exception, err.stack, @__sentry_scrubber)

            Plug.Conn.WrapperError.reraise(err)

          exc ->
            :ok =
              Sentry.PlugCapture.__capture_exception__(exc, __STACKTRACE__, @__sentry_scrubber)

            :erlang.raise(:error, exc, __STACKTRACE__)
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

  @doc false
  def __capture_exception__(exception, stacktrace, scrubber) do
    # We can't pattern match here, because we're not guaranteed to have
    # Phoenix available.
    exception =
      if is_struct(exception, Phoenix.ActionClauseError) do
        update_in(exception, [Access.key!(:args), Access.all()], fn
          conn when is_struct(conn, Plug.Conn) -> apply_scrubber(conn, scrubber)
          other -> other
        end)
      else
        exception
      end

    _ =
      Sentry.capture_exception(exception,
        stacktrace: stacktrace,
        event_source: :plug,
        handled: false
      )

    :ok
  end

  @doc false
  def default_scrubber(conn) do
    %{
      conn
      | cookies: %{},
        req_headers: Sentry.PlugContext.default_header_scrubber(conn),
        params: Sentry.PlugContext.default_body_scrubber(conn)
    }
  end

  defp apply_scrubber(conn, {mod, fun, args} = _scrubber) do
    case apply(mod, fun, [conn | args]) do
      conn when is_struct(conn, Plug.Conn) -> conn
      other -> raise ":scrubber function must return a Plug.Conn struct, got: #{inspect(other)}"
    end
  end
end
