defmodule Sentry.MetricBatch do
  @moduledoc """
  A batch of metric events to be sent in a single envelope item.

  According to the Sentry Metrics Protocol, metrics are sent in batches
  within a single envelope item with content type `application/vnd.sentry.items.trace-metric+json`.
  """
  @moduledoc since: "13.0.0"

  alias Sentry.Metric

  @type t() :: %__MODULE__{
          metrics: [Metric.t()]
        }

  @enforce_keys [:metrics]
  defstruct [:metrics]
end
