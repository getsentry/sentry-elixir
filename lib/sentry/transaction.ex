defmodule Sentry.Transaction do
  @type t() :: %__MODULE__{}

  alias Sentry.{Config, UUID}

  @enforce_keys [:event_id, :span_id, :spans]

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

  # Used to then encode the returned map to JSON.
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
    |> Sentry.Span.to_map()
    |> Map.put(:spans, Enum.map(child_spans, &Sentry.Span.to_map/1))
    |> Map.drop([:description])
    |> Map.merge(transaction_attrs)
  end
end

defmodule Sentry.Span do
  @enforce_keys ~w(span_id trace_id start_timestamp timestamp)a

  defstruct [
    :trace_id,
    :span_id,
    :parent_span_id,
    :start_timestamp,
    :timestamp,
    :description,
    :op,
    :status,
    :tags,
    :data,
    :origin
  ]

  # Used to then encode the returned map to JSON.
  @doc false
  def to_map(%__MODULE__{} = span) do
    Map.from_struct(span)
  end
end
