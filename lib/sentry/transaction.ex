defmodule Sentry.Transaction do
  @moduledoc """
  The struct for the **transaction** interface.

  See <https://develop.sentry.dev/sdk/data-model/event-payloads/transaction/>.
  """

  @moduledoc since: "11.0.0"

  alias Sentry.{Config, UUID, Interfaces, Interfaces.Span, Interfaces.SDK}

  @sdk %Interfaces.SDK{
    name: "sentry-elixir",
    version: Mix.Project.config()[:version]
  }

  @typedoc """
  A map of measurements.

  See
  [here](https://github.com/getsentry/sentry/blob/a8c960a933d2ded5225841573d8fc426a482ca9c/static/app/utils/discover/fields.tsx#L654-L676)
  for the list of supported keys (which could change in the future).
  """
  @typedoc since: "11.0.0"
  @type measurements() :: %{
          optional(key :: atom()) => %{
            required(:value) => number(),
            optional(:unit) => String.t()
          }
        }

  @typedoc """
  Transaction information.

  Should only be set by integrations and not developers directly.
  """
  @typedoc since: "11.0.0"
  @type transaction_info() :: %{
          required(:source) => String.t()
        }

  @typedoc since: "11.0.0"
  @type t() ::
          %__MODULE__{
            # Required
            event_id: UUID.t(),
            start_timestamp: String.t() | number(),
            timestamp: String.t() | number(),
            platform: String.t(),
            # See https://develop.sentry.dev/sdk/data-model/event-payloads/contexts/#trace-context
            contexts: %{
              required(:trace) => %{
                required(:trace_id) => String.t(),
                required(:span_id) => String.t(),
                optional(:parent_span_id) => String.t(),
                optional(:op) => String.t(),
                optional(:description) => String.t(),
                optional(:status) => String.t()
              }
            },

            # Optional
            environment: String.t(),
            transaction: String.t(),
            transaction_info: transaction_info(),
            measurements: measurements(),
            tags: map(),
            data: map(),

            # Interfaces
            spans: [Span.t()],
            sdk: SDK.t()
          }

  @enforce_keys [:event_id, :span_id, :start_timestamp, :timestamp]

  defstruct @enforce_keys ++
              [
                :spans,
                :transaction,
                :transaction_info,
                :contexts,
                :measurements,
                :sdk,
                :platform,
                :environment,
                :tags,
                :data
              ]

  @doc false
  def new(attrs) do
    struct!(
      __MODULE__,
      attrs
      |> Map.put(:event_id, UUID.uuid4_hex())
      |> Map.put(:environment, Config.environment_name())
      |> Map.put(:sdk, @sdk)
      |> Map.put(:platform, "elixir")
    )
  end

  @doc false
  def to_payload(%__MODULE__{} = transaction) do
    transaction
    |> Map.from_struct()
    |> Map.put(:type, "transaction")
    |> update_in([Access.key(:spans, []), Access.all()], &Map.from_struct/1)
  end
end
