defmodule Sentry.PlugCapture do
  @moduledoc """
  Ensures proper error reporting for Plug applications that use Cowboy.

  It is intended for usage with `Sentry.PlugContext`, which adds relevant request
  metadata to the Sentry context before errors are captured.

  > #### Only for Cowboy {: .info}
  >
  > `Sentry.PlugCapture` is only recommended for Cowboy applications.
  > For applications running on Bandit, which is the most recent default webserver
  > in Phoenix, `Sentry.PlugContext` should be enough, and using `Sentry.PlugCapture`
  > might result in duplicate errors.

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

    1. if the error is `Phoenix.ActionClauseError`, we scrub the `Plug.Conn` in the
      `args` field of that exception, and mirror that conn's scrubbed params onto the
      action's standalone params argument so both are redacted consistently

  Scrubbing goes through the same `Sentry.Scrubber` implementation as
  `Sentry.PlugContext`, so it honors the per-field scrubbers (`:body_scrubber`,
  `:header_scrubber`, `:cookie_scrubber`, `:url_scrubber`) configured on
  `Sentry.PlugContext` for the current request.

  Otherwise, we don't perform any scrubbing. To configure scrubbing, you can use the
  `:scrubber` option (see below).

  ## Options

    * `:scrubber` (since v9.1.0) - a term of type `{module, function, args}` that
      will be invoked to scrub sensitive data from `Plug.Conn` structs. The
      `Plug.Conn` struct is prepended to `args` before invoking the function,
      so that the final function will be called as `apply(module, function, [conn | args])`.
      The function must return a `Plug.Conn` struct. By default, the built-in
      scrubber delegates to `Sentry.Scrubber.scrub/1`, which honors any
      `:body_scrubber`, `:header_scrubber`, `:cookie_scrubber`, or
      `:url_scrubber` opts configured on `Sentry.PlugContext` for the current
      request. When no `Sentry.PlugContext` has run, falls back to the
      defaults defined by `Sentry.Scrubber.scrub/2`:

      * scrubs *all* cookies (`cookies` and `req_cookies`)
      * drops sensitive request headers (`authorization`, `authentication`, `cookie`)
      * scrubs sensitive params (`password`, `passwd`, `secret`) in `params`,
        `body_params`, and `query_params`
      * clears `assigns` (where auth libraries store user structs and tokens)
      * reduces `private` to an allow-list of framework metadata, dropping
        everything else (notably the decoded session under `:plug_session`);
        configurable via the `scrubber: [conn_private_allow_list: ...]` option

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
    # `Phoenix.ActionClauseError` is the one error whose args we know the shape of —
    # a controller action is invoked as `apply(controller, action, [conn, conn.params])`.
    # We handle it explicitly: `StacktraceScrubber` does the generic per-arg scrubbing,
    # and we instruct it (via the callback) to scrub the conn through the configured
    # `:scrubber` and mirror the conn's scrubbed params onto the standalone params arg.
    exception =
      if is_struct(exception, Phoenix.ActionClauseError) do
        Sentry.Scrubber.StacktraceScrubber.scrub(
          exception,
          &scrub_action_clause_args(&1, scrubber)
        )
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

  defp scrub_action_clause_args(args, scrubber) do
    conn = Enum.find(args, &is_struct(&1, Plug.Conn))
    scrubbed_conn = apply_scrubber(conn, scrubber)
    params = conn.params

    Enum.map(args, fn
      ^conn -> scrubbed_conn
      ^params -> scrubbed_conn.params
      other -> Sentry.Scrubber.scrub(other)
    end)
  end

  @doc false
  def default_scrubber(conn), do: Sentry.Scrubber.scrub(conn)

  defp apply_scrubber(conn, {mod, fun, args} = _scrubber) do
    case apply(mod, fun, [conn | args]) do
      conn when is_struct(conn, Plug.Conn) -> conn
      other -> raise ":scrubber function must return a Plug.Conn struct, got: #{inspect(other)}"
    end
  end
end
