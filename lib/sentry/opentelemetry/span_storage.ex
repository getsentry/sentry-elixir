defmodule Sentry.OpenTelemetry.SpanStorage do
  @moduledoc false
  use GenServer

  defstruct [:cleanup_interval]

  @table :span_storage
  @cleanup_interval :timer.minutes(5)
  @span_ttl :timer.minutes(30)

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    _table =
      if :ets.whereis(@table) == :undefined do
        :ets.new(@table, [:named_table, :public, :bag])
      end

    cleanup_interval = Keyword.get(opts, :cleanup_interval, @cleanup_interval)
    schedule_cleanup(cleanup_interval)

    {:ok, %__MODULE__{cleanup_interval: cleanup_interval}}
  end

  @impl true
  def handle_info(:cleanup_stale_spans, state) do
    cleanup_stale_spans()
    schedule_cleanup(state.cleanup_interval)
    {:noreply, state}
  end

  def store_span(span_data) when span_data.parent_span_id == nil do
    stored_at = System.system_time(:second)

    case :ets.lookup(@table, {:root_span, span_data.span_id}) do
      [] -> :ets.insert(@table, {{:root_span, span_data.span_id}, {span_data, stored_at}})
      _ -> :ok
    end
  end

  def store_span(span_data) do
    stored_at = System.system_time(:second)
    _ = :ets.insert(@table, {span_data.parent_span_id, {span_data, stored_at}})
  end

  def get_root_span(span_id) do
    case :ets.lookup(@table, {:root_span, span_id}) do
      [{{:root_span, ^span_id}, {span, _stored_at}}] -> span
      [] -> nil
    end
  end

  def get_child_spans(parent_span_id) do
    :ets.lookup(@table, parent_span_id)
    |> Enum.map(fn {_parent_id, {span, _stored_at}} -> span end)
  end

  def update_span(span_data) do
    stored_at = System.system_time(:second)

    if span_data.parent_span_id == nil do
      case :ets.lookup(@table, {:root_span, span_data.span_id}) do
        [] ->
          :ets.insert(@table, {{:root_span, span_data.span_id}, {span_data, stored_at}})

        _ ->
          :ets.delete(@table, {:root_span, span_data.span_id})
          :ets.insert(@table, {{:root_span, span_data.span_id}, {span_data, stored_at}})
      end
    else
      existing_spans = :ets.lookup(@table, span_data.parent_span_id)

      Enum.each(existing_spans, fn {parent_id, {span, stored_at}} ->
        if span.span_id == span_data.span_id do
          :ets.delete_object(@table, {parent_id, {span, stored_at}})
          :ets.insert(@table, {span_data.parent_span_id, {span_data, stored_at}})
        end
      end)
    end

    :ok
  end

  def remove_span(span_id) do
    case get_root_span(span_id) do
      nil ->
        :ok

      _root_span ->
        :ets.delete(@table, {:root_span, span_id})
        remove_child_spans(span_id)
    end
  end

  def remove_child_spans(parent_span_id) do
    :ets.delete(@table, parent_span_id)
    :ok
  end

  defp schedule_cleanup(interval) do
    Process.send_after(self(), :cleanup_stale_spans, interval)
  end

  defp cleanup_stale_spans do
    now = System.system_time(:second)
    cutoff_time = now - @span_ttl

    :ets.match_object(@table, {{:root_span, :_}, {:_, :_}})
    |> Enum.each(fn {{:root_span, span_id}, {_span, stored_at}} ->
      if stored_at < cutoff_time do
        remove_span(span_id)
      end
    end)

    :ets.match_object(@table, {:_, {:_, :_}})
    |> Enum.each(fn {parent_id, {_span, stored_at}} = object ->
      cond do
        not is_nil(get_root_span(parent_id)) and stored_at < cutoff_time ->
          :ets.delete_object(@table, object)

        is_nil(get_root_span(parent_id)) and stored_at < cutoff_time ->
          :ets.delete_object(@table, object)

        true ->
          :ok
      end
    end)
  end
end
