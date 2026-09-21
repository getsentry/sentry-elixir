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
      The function must return a `Plug.Conn` struct; if it returns anything else,
      or if it crashes, scrubbing falls back to the built-in scrubber (see
      *Crashing Callbacks* below). By default, the built-in
      scrubber delegates to `Sentry.Scrubber.scrub/1`, which honors any
      `:body_scrubber`, `:header_scrubber`, `:cookie_scrubber`, or
      `:url_scrubber` opts configured on `Sentry.PlugContext` for the current
      request. When no `Sentry.PlugContext` has run, falls back to the
      defaults defined by `Sentry.Scrubber.scrub/2`:

      * scrubs *all* cookies (`cookies` and `req_cookies`)
      * drops sensitive request headers (`authorization`, `authentication`, `cookie`)
      * scrubs `params` and `body_params` through the configured `body_scrubber`
        (defaulting to the sensitive params in `Sentry.Scrubber.default_param_keys/0`; a
        `nil` `body_scrubber` empties both), and scrubs the same sensitive params
        in `query_params` and `path_params`
      * derives `request_path`, `path_info` and `query_string` from the URL the
        configured `url_scrubber` returns, so a scrubber that redacts a path
        segment redacts it here too; `query_string` is scrubbed against the
        sensitive params either way
      * clears `assigns` (where auth libraries store user structs and tokens)
      * reduces `private` to an allow-list of framework metadata, dropping
        everything else (notably the decoded session under `:plug_session`);
        configurable via the `scrubber: [conn_private_allow_list: ...]` option

  ## Crashing Callbacks

  This module captures the application's exception from inside `c:Plug.call/2`,
  where a failure of its own would replace the error the application raised. It
  cannot: if anything in the capture path raises, throws, or exits - the
  `:scrubber` callback, the scrubbing of the exception, or the reporting
  itself - Sentry catches the failure and re-raises **the application's
  original exception, unchanged**. The failure is logged at the `:error` level
  with the `:sentry` logger domain, so the SDK never reports its own failure as
  an event.

  Only the reporting degrades, and only as far as the failure forces:

  | Failure | What Sentry still reports |
  | --- | --- |
  | The `:scrubber` crashes, or returns something other than a `Plug.Conn` | The event, with the conn scrubbed by the built-in scrubber, `Sentry.Scrubber.scrub/1` |
  | Scrubbing a `Phoenix.ActionClauseError` fails for any other reason | The event, with each of the exception's arguments scrubbed on its own, without mirroring the conn's scrubbed params onto the action's params argument |
  | Capturing the event itself fails | Nothing - the log is the only record of the error |

  > #### A crashed scrubber reports more, not less {: .warning}
  >
  > The fallback redacts the keys listed in `Sentry.Scrubber.default_param_keys/0`
  > and `Sentry.Scrubber.default_header_keys/0`, and nothing more. Data that only
  > a custom `:scrubber` was dropping is sent to Sentry for as long as that
  > scrubber keeps failing, and the error-level log is the only signal.

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
            :ok = Sentry.PlugCapture.__capture_message__(message, stack)
            :erlang.raise(kind, reason, stack)
        end
      end
    end
  end

  @doc false
  def __capture_exception__(exception, stacktrace, scrubber) do
    _ =
      guard("Sentry failed to capture an exception from Plug", fn ->
        Sentry.capture_exception(scrub_exception(exception, scrubber),
          stacktrace: stacktrace,
          event_source: :plug,
          handled: false
        )
      end)

    :ok
  end

  @doc false
  def __capture_message__(message, stacktrace) do
    _ =
      guard("Sentry failed to capture a message from Plug", fn ->
        Sentry.capture_message(message, stacktrace: stacktrace, event_source: :plug)
      end)

    :ok
  end

  # `Phoenix.ActionClauseError` is the one error whose args we know the shape of -
  # a controller action is invoked as `apply(controller, action, [conn, conn.params])`.
  # We handle it explicitly: `StacktraceScrubber` does the generic per-arg scrubbing,
  # and we instruct it (via the callback) to scrub the conn through the configured
  # `:scrubber` and mirror the conn's scrubbed params onto the standalone params arg.
  defp scrub_exception(exception, scrubber) do
    if is_struct(exception, Phoenix.ActionClauseError) do
      case guard("Sentry failed to scrub a Phoenix.ActionClauseError", fn ->
             Sentry.Scrubber.StacktraceScrubber.scrub(
               exception,
               &scrub_action_clause_args(&1, scrubber)
             )
           end) do
        {:ok, scrubbed} -> scrubbed
        :failed -> Sentry.Scrubber.StacktraceScrubber.scrub(exception)
      end
    else
      exception
    end
  end

  defp guard(description, fun) do
    {:ok, fun.()}
  catch
    kind, reason ->
      Sentry.LoggerUtils.error(
        description <> ": " <> Exception.format(kind, reason, __STACKTRACE__)
      )

      :failed
  end

  defp scrub_action_clause_args(args, scrubber) do
    case Enum.find(args, &is_struct(&1, Plug.Conn)) do
      nil ->
        Sentry.Scrubber.StacktraceScrubber.scrub_args(args)

      conn ->
        scrubbed_conn = apply_scrubber(conn, scrubber)
        params = conn.params

        Enum.map(args, fn
          ^conn -> scrubbed_conn
          ^params -> scrubbed_conn.params
          other -> Sentry.Scrubber.scrub(other)
        end)
    end
  end

  @doc false
  def default_scrubber(conn), do: Sentry.Scrubber.scrub(conn)

  defp apply_scrubber(conn, {mod, fun, args} = _scrubber) do
    case Sentry.Callback.run(:scrubber, fn ->
           case apply(mod, fun, [conn | args]) do
             scrubbed when is_struct(scrubbed, Plug.Conn) ->
               scrubbed

             other ->
               raise ":scrubber function must return a Plug.Conn struct, got: #{inspect(other)}"
           end
         end) do
      {:ok, scrubbed} -> scrubbed
      :failed -> default_scrubber(conn)
    end
  end
end
