defmodule Sentry.EventFilter do
  @moduledoc """
  A behaviour for filtering events to send to Sentry.

  There's only one callback to implement, `c:exclude_exception?/2`.

  ## Usage

  To use a custom event filter module, configure the `:filter` option
  in the `:sentry` application. For example:

      config :sentry,
        filter: MyApp.SentryEventFilter

  The default event filter is `Sentry.DefaultEventFilter`.

  ## Examples

  As an example, if you wanted to exclude all `ArithmeticError` exceptions
  and nothing else:

      defmodule MyApp.SentryEventFilter do
        @behaviour Sentry.EventFilter

        @impl true
        def exclude_exception?(%ArithmeticError{}, _source), do: true
        def exclude_exception?(_exception, _source), do: false
      end

  Alternatively, if you wanted to skip all non-500 exceptions in a Plug app:

      defmodule MyApp.SentryEventFilter do
        @behaviour Sentry.EventFilter

        @impl true
        def exclude_exception?(exception, _source) do
          Plug.Exception.status(exception) < 500
        end
      end

  If you want to exclude some specific exceptions but then fall back to the
  default event filter, you can do something like this:

      defmodule MyApp.SentryEventFilter do
        @behaviour Sentry.EventFilter

        @impl true
        def exclude_exception?(%ArithmeticError{}, _source) do
          true
        end

        def exclude_exception?(exception, source) do
          Sentry.DefaultEventFilter.exclude_exception?(exception, source)
        end
      end

  """

  @doc """
  Should return whether the given event should be *excluded* from being
  reported to Sentry.

  `exception` is the exception that was raised.

  `source` is the source of the event. Events from `Sentry.PlugCapture`
  will have `:plug` as a source and events from `Sentry.LoggerBackend`
  will have `:logger` as the source. A custom source can also be specified
  by passing the `:event_source` option to `Sentry.capture_exception/2`.
  """
  @callback exclude_exception?(exception :: Exception.t(), source :: atom) :: boolean
end
