defmodule Sentry.EventFilter do
  @moduledoc """
  This module defines a Behaviour for filtering Sentry events.
  There is one callback to implement. The first argument will be
  the exception reported, and the second is the source. Events
  from `Sentry.Plug` will have :plug as a source, `Sentry.Phoenix.Endpoint`
  will have `:endpoint` and events from `Sentry.LoggerBackend` will have
  `:logger` as the source. A custom source can also be specified by passing
  the `event_source` option to `Sentry.capture_exception/2`.

  As an example, if you wanted to exclude any `ArithmeticError` exceptions:

      defmodule MyApp.SentryEventFilter do
        @behaviour Sentry.EventFilter

        def exclude_exception?(%ArithmeticError{}, _source), do: true
        def exclude_exception?(_exception, _source), do: false
      end
  """

  @doc """
  Callback that returns whether an exception should be excluded from
  being reported
  """
  @callback exclude_exception?(Exception.t(), atom) :: boolean
end
