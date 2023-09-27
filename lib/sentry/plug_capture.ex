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

  Like `Sentry.PlugContext`, this module also supports scrubbing sensitive data
  out of errors. However, this module has to do some *guessing* to figure
  out if there are `Plug.Conn` structs to scrub. Right now, the strategy we
  use follows these steps:

    1. if the error is `Phoenix.ActionClauseError`, we scrub both the
       conn as well as the params

  Otherwise, we don't perform any scrubbing. To configure scrubbing, you can
  use similar options to `Sentry.PlugContext`:

    * `:body_scrubber` for scrubbing the body (defaults to `Sentry.PlugContext.default_body_scrubber/1`)
    * `:header_scrubber` for scrubbing the headers (defaults to `Sentry.PlugContext.default_header_scrubber/1`)
    * `:cookie_scrubber` for scrubbing the cookies (defaults to `Sentry.PlugContext.default_cookie_scrubber/1`)

  You can pass these options when you `use Sentry.PlugCapture`.

      use Sentry.PlugCapture, body_scrubber: {MyApp.Scrubber, :scrub_body}

  By default, the built-in scrubber does this:

    * scrubs *all* cookies
    * scrubs sensitive headers just like `Sentry.PlugContext.default_header_scrubber/1`
    * scrubs sensitive body params just like `Sentry.PlugContext.default_body_scrubber/1`

  """

  defmacro __using__(opts) do
    quote do
      @sentry_plug_capture_scrubber Keyword.get(
                                      unquote(Macro.escape(opts)),
                                      :scrubber,
                                      {unquote(__MODULE__), :default_scrubber, []}
                                    )

      unless match?(
               {mod, fun, args} when is_atom(mod) and is_atom(fun) and is_list(args),
               @sentry_plug_capture_scrubber
             ) do
        raise ArgumentError, """
        expected :scrubber to be a tuple of the form {module, function, args}, got: \
        #{inspect(@sentry_plug_capture_opts)}\
        """
      end

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

            Sentry.PlugCapture.capture_exception(
              exception,
              err.stack,
              @sentry_plug_capture_scrubber
            )

            Plug.Conn.WrapperError.reraise(err)

          exception ->
            Sentry.PlugCapture.capture_exception(
              exception,
              __STACKTRACE__,
              @sentry_plug_capture_scrubber
            )

            :erlang.raise(:error, exception, __STACKTRACE__)
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
  def capture_exception(exception, stacktrace, {_mod, _fun, _args} = scrubber) do
    # We can't pattern match here, because we're not guaranteed to have
    # Phoenix available.
    exception =
      cond do
        is_struct(exception, Phoenix.ActionClauseError) ->
          update_in(exception, [Access.key!(:args), Access.all()], fn
            conn when is_struct(conn, Plug.Conn) -> apply_scrubber(conn, scrubber)
            other -> other
          end)

        true ->
          exception
      end

    Sentry.capture_exception(exception, stacktrace: stacktrace, event_source: :plug)
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

  defp apply_scrubber(conn, {mod, fun, args}) do
    apply(mod, fun, [conn | args])
  end
end
