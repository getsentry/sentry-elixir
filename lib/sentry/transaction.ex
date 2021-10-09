defmodule Sentry.Transaction do

  @type t :: %__MODULE__{
    event_id: nil,
    name: nil,
    tags: %{},
    sdk: nil,
    platform: nil,
    timestamp: DateTime.t() | nil,
    start_timestamp: nil,
    spans: [any()],
    contexts: %{String.t() => map()}
  }

  defstruct event_id: nil,
            name: nil,
            tags: %{},
            sdk: nil,
            platform: nil,
            timestamp: nil,
            start_timestamp: nil,
            spans: [],
            contexts: %{}

  def new() do
    %__MODULE__{}
  end

  @spec finish(t()) :: t()
  def finish(transaction) do
    %{transaction | timestamp: DateTime.utc_now()}
  end
end
