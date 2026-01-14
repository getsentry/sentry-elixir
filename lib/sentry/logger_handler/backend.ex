defmodule Sentry.LoggerHandler.Backend do
  @moduledoc false

  # Behaviour for LoggerHandler backends.
  #
  # This allows different handling strategies for log events:
  # - ErrorBackend: Captures errors/crashes to Sentry's error API
  # - LogsBackend: Sends structured logs to Sentry's Logs Protocol

  @doc """
  Called when a log event is received.

  The handler_id is provided for backends that need it (e.g., for rate limiting).

  Returns `:ok` regardless of whether the event was handled,
  to allow multiple backends to process the same event.
  """
  @callback handle_event(:logger.log_event(), config :: map(), handler_id :: atom()) :: :ok
end
