defmodule Sentry.OpenTelemetry.SpanStorage do
  @moduledoc false
  use GenServer

  defstruct [:cleanup_interval, :table_name]

  @cleanup_interval :timer.minutes(5)
  @span_ttl :timer.minutes(30)

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    table_name = Keyword.get(opts, :table_name, default_table_name())
    cleanup_interval = Keyword.get(opts, :cleanup_interval, @cleanup_interval)

    if :ets.whereis(table_name) == :undefined do
      :ets.new(table_name, [:named_table, :public, :bag])
    end

    schedule_cleanup(cleanup_interval)

    {:ok, %__MODULE__{cleanup_interval: cleanup_interval, table_name: table_name}}
  end

  @impl true
  def handle_info(:cleanup_stale_spans, state) do
    cleanup_stale_spans(state.table_name)
    schedule_cleanup(state.cleanup_interval)

    {:noreply, state}
  end

  def store_span(span_data, opts \\ [])

  def store_span(span_data, opts) when span_data.parent_span_id == nil do
    table_name = Keyword.get(opts, :table_name, default_table_name())
    stored_at = System.system_time(:second)

    case :ets.lookup(table_name, {:root_span, span_data.span_id}) do
      [] -> insert_root_span(span_data, stored_at, table_name)
      _ -> :ok
    end
  end

  def store_span(span_data, opts) do
    table_name = Keyword.get(opts, :table_name, default_table_name())
    stored_at = System.system_time(:second)
    _ = :ets.insert(table_name, {span_data.parent_span_id, {span_data, stored_at}})
  end

  def get_root_span(span_id, opts \\ []) do
    table_name = Keyword.get(opts, :table_name, default_table_name())

    case :ets.lookup(table_name, {:root_span, span_id}) do
      [{{:root_span, ^span_id}, span, _stored_at}] -> span
      [] -> nil
    end
  end

  def insert_root_span(span_data, stored_at, table_name) do
    :ets.insert(table_name, {{:root_span, span_data.span_id}, span_data, stored_at})
  end

  def get_child_spans(parent_span_id, opts \\ []) do
    table_name = Keyword.get(opts, :table_name, default_table_name())

    :ets.lookup(table_name, parent_span_id)
    |> Enum.map(fn {_parent_id, {span, _stored_at}} -> span end)
  end

  def update_span(span_data, opts \\ [])

  def update_span(%{parent_span_id: nil} = span_data, opts) do
    table_name = Keyword.get(opts, :table_name, default_table_name())
    stored_at = System.system_time(:second)

    case get_root_span(span_data.span_id, table_name: table_name) do
      nil ->
        insert_root_span(span_data, stored_at, table_name)

      _ ->
        :ets.delete(table_name, {:root_span, span_data.span_id})
        insert_root_span(span_data, stored_at, table_name)
    end

    :ok
  end

  def update_span(%{parent_span_id: parent_span_id} = span_data, opts) do
    table_name = Keyword.get(opts, :table_name, default_table_name())
    existing_spans = :ets.lookup(table_name, parent_span_id)

    Enum.each(existing_spans, fn {parent_id, {span, stored_at}} ->
      if span.span_id == span_data.span_id do
        :ets.delete_object(table_name, {parent_id, {span, stored_at}})
        :ets.insert(table_name, {parent_span_id, {span_data, stored_at}})
      end
    end)

    :ok
  end

  def remove_root_span(span_id, opts \\ []) do
    table_name = Keyword.get(opts, :table_name, default_table_name())

    case get_root_span(span_id, opts) do
      nil ->
        :ok

      _root_span ->
        :ets.delete(table_name, {:root_span, span_id})
        remove_child_spans(span_id, table_name: table_name)
    end
  end

  def remove_child_spans(parent_span_id, opts \\ []) do
    table_name = Keyword.get(opts, :table_name, default_table_name())
    :ets.delete(table_name, parent_span_id)
    :ok
  end

  defp schedule_cleanup(interval) do
    Process.send_after(self(), :cleanup_stale_spans, interval)
  end

  defp cleanup_stale_spans(table_name) do
    now = System.system_time(:second)
    cutoff_time = now - @span_ttl

    # Check root spans
    root_spans = :ets.match_object(table_name, {{:root_span, :_}, :_, :_})

    Enum.each(root_spans, fn {{:root_span, span_id}, _span, stored_at} ->
      if stored_at < cutoff_time do
        remove_root_span(span_id, table_name: table_name)
      end
    end)

    # Check child spans
    child_spans = :ets.match_object(table_name, {:_, {:_, :_}})

    Enum.each(child_spans, fn {_parent_id, {_span, stored_at}} = object ->
      if stored_at < cutoff_time do
        :ets.delete_object(table_name, object)
      end
    end)
  end

  defp default_table_name do
    Module.concat(__MODULE__, ETSTable)
  end
end
