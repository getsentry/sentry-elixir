defmodule Sentry.EventFilter do
  @moduledoc """
  A behaviour for filtering events to send to Sentry.

  There's only one callback to implement, `c:exclude_exception?/2`.

  > #### Soft-deprecated {: .warning}
  >
  > This behaviour is soft-deprecated in favor of filtering events through the
  > `:before_send` callback functionality. `:before_send` is described in
  > details in the documentation for the `Sentry` module. It's a more general
  > mechanism to filter or modify events before sending them to Sentry. See below for
  > an example of how to replace an event filter with a `:before_send` callback.
  >
  > In future major versions of this library, we might hard-deprecate or remove this
  > behaviour altogether.

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

  ## Replacing With `:before_send`

  Let's look at an example of how to filter non-500 exceptions in a Plug app through
  the `:before_send` callback. We can start with a module:

      defmodule MyApp.SentryEventFilter do
        def filter_non_500(%Sentry.Event{original_exception: exception} = event) do
          cond do
            if Plug.Exception.status(exception) < 500 ->
              false

            # Fall back to the default event filter.
            Sentry.DefaultEventFilter.exclude_exception?(exception, event.source) ->
              false

            true ->
              event
          end
        end
      end

  Then, we can configure the `:before_send` callback.

      config :sentry,
        before_send: {MyApp.SentryEventFilter, :filter_non_500}

  > #### Multiple Callbacks {: .tip}
  >
  > You can only have one `:before_send` callback. If you change the value
  > of this configuration option, you'll *override* the previous callback. If you
  > want to do multiple things in a `:before_send` callback, create a function
  > that does all the things you need and register *that* as the callback.
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
