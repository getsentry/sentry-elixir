defmodule Sentry.LogBatch do
  @moduledoc """
  A batch of log events to be sent in a single envelope item.

  According to the Sentry Logs Protocol, log events are sent in batches
  within a single envelope item with content_type "application/vnd.sentry.items.log+json".
  """
  @moduledoc since: "12.0.0"

  alias Sentry.LogEvent

  @type t() :: %__MODULE__{
          log_events: [LogEvent.t()]
        }

  @enforce_keys [:log_events]
  defstruct [:log_events]
end
