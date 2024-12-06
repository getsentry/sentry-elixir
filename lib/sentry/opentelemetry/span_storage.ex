defmodule Sentry.Opentelemetry.SpanStorage do
  @moduledoc false
  use GenServer

  @table :span_storage

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, nil, name: name)
  end

  @impl true
  def init(nil) do
    _table =
      if :ets.whereis(@table) == :undefined do
        :ets.new(@table, [:named_table, :public, :bag])
      end

    {:ok, :no_state}
  end

  def store_span(span_data) when span_data.parent_span_id == nil do
    case :ets.lookup(@table, {:root_span, span_data.span_id}) do
      [] -> :ets.insert(@table, {{:root_span, span_data.span_id}, span_data})
      _ -> :ok
    end
  end

  def store_span(span_data) do
    _ = :ets.insert(@table, {span_data.parent_span_id, span_data})
  end

  def get_root_span(span_id) do
    case :ets.lookup(@table, {:root_span, span_id}) do
      [{{:root_span, ^span_id}, span}] -> span
      [] -> nil
    end
  end

  def get_child_spans(parent_span_id) do
    :ets.lookup(@table, parent_span_id)
    |> Enum.map(fn {_parent_id, span} -> span end)
  end

  def update_span(span_data) do
    if span_data.parent_span_id == nil do
      case :ets.lookup(@table, {:root_span, span_data.span_id}) do
        [] ->
          :ets.insert(@table, {{:root_span, span_data.span_id}, span_data})

        _ ->
          :ets.delete(@table, {:root_span, span_data.span_id})
          :ets.insert(@table, {{:root_span, span_data.span_id}, span_data})
      end
    else
      existing_spans = :ets.lookup(@table, span_data.parent_span_id)

      Enum.each(existing_spans, fn {parent_id, span} ->
        if span.span_id == span_data.span_id do
          :ets.delete_object(@table, {parent_id, span})
          :ets.insert(@table, {span_data.parent_span_id, span_data})
        end
      end)
    end

    :ok
  end

  def remove_span(span_id) do
    :ets.delete(@table, {:root_span, span_id})
    :ok
  end

  def remove_child_spans(parent_span_id) do
    :ets.delete(@table, parent_span_id)
    :ok
  end
end
