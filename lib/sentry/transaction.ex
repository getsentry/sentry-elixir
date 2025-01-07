defmodule Sentry.Transaction do
  @moduledoc """
  The struct for the **transaction** interface.

  See <https://develop.sentry.dev/sdk/event-payloads/transactions>.
  """

  @moduledoc since: "11.0.0"

  alias Sentry.{Config, UUID, Interfaces.Span, Interfaces.SDK}

  @typedoc since: "11.0.0"
  @type t() :: %{
          # Required
          required(:event_id) => <<_::256>>,
          required(:start_timestamp) => String.t() | number(),
          required(:timestamp) => String.t() | number(),
          required(:platform) => :elixir,
          required(:contexts) => %{
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
          optional(:environment) => String.t(),
          optional(:transaction) => String.t(),
          optional(:transaction_info) => map(),
          optional(:measurements) => map(),
          optional(:type) => String.t(),
          optional(:tags) => map(),
          optional(:data) => map(),

          # Interfaces
          optional(:spans) => [Span.t()],
          optional(:sdk) => SDK.t()
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
                :data,
                type: "transaction"
              ]

  @doc false
  def new(attrs) do
    struct!(
      __MODULE__,
      attrs
      |> Map.put(:event_id, UUID.uuid4_hex())
      |> Map.put(:environment, Config.environment_name())
    )
  end

  @doc false
  def to_payload(%__MODULE__{} = transaction) do
    transaction
    |> Map.from_struct()
    |> Map.update(:spans, [], fn spans -> Enum.map(spans, &Span.to_payload/1) end)
  end
end
