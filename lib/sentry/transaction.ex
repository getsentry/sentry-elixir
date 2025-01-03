defmodule Sentry.Transaction do
  @moduledoc """
  The struct for the **transaction** interface.

  See <https://develop.sentry.dev/sdk/event-payloads/transactions>.
  """

  @moduledoc since: "11.0.0"

  @typedoc since: "11.0.0"

  @type t() :: %__MODULE__{
          event_id: String.t(),
          environment: String.t(),
          transaction: String.t(),
          transaction_info: map(),
          contexts: map(),
          measurements: map(),
          type: String.t()
        }

  alias Sentry.{Config, UUID, Interfaces.Span}

  @enforce_keys [:event_id, :span_id, :spans, :environment]

  defstruct @enforce_keys ++
              [
                :transaction,
                :transaction_info,
                :contexts,
                :measurements,
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
  def to_map(%__MODULE__{} = transaction) do
    transaction_attrs =
      Map.take(transaction, [
        :event_id,
        :environment,
        :transaction,
        :transaction_info,
        :contexts,
        :measurements,
        :type
      ])

    {[root_span], child_spans} = Enum.split_with(transaction.spans, &is_nil(&1.parent_span_id))

    root_span
    |> Span.to_map()
    |> Map.put(:spans, Enum.map(child_spans, &Span.to_map/1))
    |> Map.drop([:description])
    |> Map.merge(transaction_attrs)
  end
end
