defmodule Sentry.Telemetry.SpanStorage do
  use GenServer

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  def init(_) do
    {:ok, %{root_spans: %{}, child_spans: %{}}}
  end

  def store_span(span_data) do
    GenServer.call(__MODULE__, {:store_span, span_data})
  end

  def get_root_span(span_id) do
    GenServer.call(__MODULE__, {:get_root_span, span_id})
  end

  def get_child_spans(parent_span_id) do
    GenServer.call(__MODULE__, {:get_child_spans, parent_span_id})
  end

  def update_span(span_data) do
    GenServer.call(__MODULE__, {:update_span, span_data})
  end

  def handle_call({:store_span, span_data}, _from, state) do
    if span_data[:parent_span_id] == :undefined do
      new_state = put_in(state, [:root_spans, span_data[:span_id]], span_data)
      {:reply, :ok, new_state}
    else
      new_state =
        update_in(state, [:child_spans, span_data[:parent_span_id]], fn spans ->
          (spans || []) ++ [span_data]
        end)

      {:reply, :ok, new_state}
    end
  end

  def handle_call({:get_root_span, span_id}, _from, state) do
    {:reply, state.root_spans[span_id], state}
  end

  def handle_call({:get_child_spans, parent_span_id}, _from, state) do
    {:reply, state.child_spans[parent_span_id] || [], state}
  end

  def handle_call({:update_span, span_data}, _from, state) do
    if span_data[:parent_span_id] == :undefined do
      new_state = put_in(state, [:root_spans, span_data[:span_id]], span_data)
      {:reply, :ok, new_state}
    else
      new_state =
        update_in(state, [:child_spans, span_data[:parent_span_id]], fn spans ->
          Enum.map(spans || [], fn span ->
            if span[:span_id] == span_data[:span_id], do: span_data, else: span
          end)
        end)

      {:reply, :ok, new_state}
    end
  end
end
