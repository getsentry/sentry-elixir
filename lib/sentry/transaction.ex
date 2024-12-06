defmodule Sentry.Transaction do
  @type t() :: %__MODULE__{}

  alias Sentry.{UUID}

  defstruct [
    :event_id,
    :start_timestamp,
    :timestamp,
    :transaction,
    :transaction_info,
    :status,
    :contexts,
    :request,
    :measurements,
    spans: [],
    type: "transaction"
  ]

  def new(attrs) do
    struct(__MODULE__, Map.put(attrs, :event_id, UUID.uuid4_hex()))
  end

  # Used to then encode the returned map to JSON.
  @doc false
  def to_map(%__MODULE__{} = transaction) do
    Map.put(
      Map.from_struct(transaction),
      :spans,
      Enum.map(transaction.spans, &Sentry.Span.to_map(&1))
    )
  end
end

defmodule Sentry.Span do
  defstruct [
    :op,
    :start_timestamp,
    :timestamp,
    :description,
    :span_id,
    :parent_span_id,
    :trace_id,
    :tags,
    :data,
    :origin,
    :status
  ]

  # Used to then encode the returned map to JSON.
  @doc false
  def to_map(%__MODULE__{} = span) do
    Map.from_struct(span)
  end
end
