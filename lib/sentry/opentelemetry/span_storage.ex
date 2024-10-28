defmodule Sentry.Opentelemetry.SpanStorage do
  @moduledoc false

  @root_spans_table :sentry_root_spans
  @child_spans_table :sentry_child_spans

  def setup do
    case :ets.whereis(@root_spans_table) do
      :undefined ->
        :ets.new(@root_spans_table, [:set, :public, :named_table])

      _ ->
        :ok
    end

    case :ets.whereis(@child_spans_table) do
      :undefined ->
        :ets.new(@child_spans_table, [:bag, :public, :named_table])

      _ ->
        :ok
    end

    :ok
  end

  def store_span(span_data) do
    if span_data.parent_span_id == nil do
      :ets.insert(@root_spans_table, {span_data.span_id, span_data})
    else
      :ets.insert(@child_spans_table, {span_data.parent_span_id, span_data})
    end

    :ok
  end

  def get_root_span(span_id) do
    case :ets.lookup(@root_spans_table, span_id) do
      [{^span_id, span}] -> span
      [] -> nil
    end
  end

  def get_child_spans(parent_span_id) do
    :ets.lookup(@child_spans_table, parent_span_id)
    |> Enum.map(fn {_parent_id, span} -> span end)
  end

  def update_span(span_data) do
    if span_data.parent_span_id == nil do
      :ets.insert(@root_spans_table, {span_data.span_id, span_data})
    else
      existing_spans = :ets.lookup(@child_spans_table, span_data.parent_span_id)

      :ets.delete(@child_spans_table, span_data.parent_span_id)

      Enum.each(existing_spans, fn {parent_id, span} ->
        if span.span_id != span_data.span_id do
          :ets.insert(@child_spans_table, {parent_id, span})
        end
      end)

      :ets.insert(@child_spans_table, {span_data.parent_span_id, span_data})
    end

    :ok
  end

  def remove_span(span_id) do
    :ets.delete(@root_spans_table, span_id)
    :ok
  end

  def remove_child_spans(parent_span_id) do
    :ets.delete(@child_spans_table, parent_span_id)
    :ok
  end
end
