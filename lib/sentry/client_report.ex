defmodule Sentry.ClientReport do
  @moduledoc """
  This module represents the data structure for a **client report**.

  Client reports are used to provide insights into which events are being
  dropped (that is, not sent to Sentry) and for what reason.

  This module is responsible for recording, storing, and periodically sending these client
  reports to Sentry. You can choose to turn off these reports by configuring the
  `:send_client_reports` option.

  Refer to <https://develop.sentry.dev/sdk/client-reports/> for more details.

  *Available since v10.8.0*.
  """

  @moduledoc since: "10.8.0"

  @client_report_reasons [
    :ratelimit_backoff,
    :queue_overflow,
    :cache_overflow,
    :network_error,
    :sample_rate,
    :before_send,
    :event_processor,
    :insufficient_data,
    :backpressure,
    :send_error,
    :internal_sdk_error
  ]

  @typedoc """
  The possible reasons of the discarded event.
  """
  @typedoc since: "10.8.0"
  @type reason() ::
          unquote(Enum.reduce(@client_report_reasons, &quote(do: unquote(&1) | unquote(&2))))

  @typedoc """
  The struct for a **client report**.
  """
  @typedoc since: "10.8.0"
  @type t() :: %__MODULE__{
          timestamp: String.t() | number(),
          discarded_events: [%{reason: reason(), category: String.t(), quantity: pos_integer()}]
        }

  @enforce_keys [:timestamp, :discarded_events]
  defstruct [:timestamp, discarded_events: %{}]

  @doc false
  @spec reasons() :: [reason(), ...]
  def reasons, do: @client_report_reasons
end
