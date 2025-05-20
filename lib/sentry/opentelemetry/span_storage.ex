defmodule Sentry.OpenTelemetry.SpanStorage do
  @moduledoc false
  use GenServer

  defstruct [:cleanup_interval, :table_name]

  alias Sentry.OpenTelemetry.SpanRecord

  @cleanup_interval :timer.minutes(5)

  @span_ttl 30 * 60

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    table_name = Keyword.get(opts, :table_name, default_table_name())
    cleanup_interval = Keyword.get(opts, :cleanup_interval, @cleanup_interval)

    _ = :ets.new(table_name, [:named_table, :public, :ordered_set])

    schedule_cleanup(cleanup_interval)

    {:ok, %__MODULE__{cleanup_interval: cleanup_interval, table_name: table_name}}
  end

  @impl true
  def handle_info(:cleanup_stale_spans, state) do
    cleanup_stale_spans(state.table_name)
    schedule_cleanup(state.cleanup_interval)

    {:noreply, state}
  end

  @spec store_span(SpanRecord.t(), keyword()) :: true
  def store_span(span_data, opts \\ [])

  def store_span(span_data, opts) when span_data.parent_span_id == nil do
    table_name = Keyword.get(opts, :table_name, default_table_name())
    stored_at = System.system_time(:second)

    :ets.insert(table_name, {{:root_span, span_data.span_id}, span_data, stored_at})
  end

  def store_span(span_data, opts) do
    table_name = Keyword.get(opts, :table_name, default_table_name())

    stored_at = System.system_time(:second)
    key = {:child_span, span_data.parent_span_id, span_data.span_id}

    :ets.insert(table_name, {key, span_data, stored_at})
  end

  @spec get_root_span(String.t(), keyword()) :: SpanRecord.t() | nil
  def get_root_span(span_id, opts \\ []) do
    table_name = Keyword.get(opts, :table_name, default_table_name())

    case :ets.lookup(table_name, {:root_span, span_id}) do
      [{{:root_span, ^span_id}, span, _stored_at}] -> span
      [] -> nil
    end
  end

  @spec get_child_spans(String.t(), keyword()) :: [SpanRecord.t()]
  def get_child_spans(parent_span_id, opts \\ []) do
    table_name = Keyword.get(opts, :table_name, default_table_name())

    :ets.match_object(table_name, {{:child_span, parent_span_id, :_}, :_, :_})
    |> Enum.map(fn {_key, span_data, _stored_at} -> span_data end)
    |> Enum.sort_by(& &1.start_time)
  end

  @spec update_span(SpanRecord.t(), keyword()) :: :ok
  def update_span(span_data, opts \\ [])

  def update_span(%{parent_span_id: nil} = span_data, opts) do
    table_name = Keyword.get(opts, :table_name, default_table_name())

    stored_at = System.system_time(:second)
    key = {:root_span, span_data.span_id}

    :ets.update_element(table_name, key, [{2, span_data}, {3, stored_at}])

    :ok
  end

  def update_span(%{parent_span_id: parent_span_id} = span_data, opts) do
    table_name = Keyword.get(opts, :table_name, default_table_name())

    stored_at = System.system_time(:second)
    key = {:child_span, parent_span_id, span_data.span_id}

    :ets.update_element(table_name, key, [{2, span_data}, {3, stored_at}])

    :ok
  end

  @spec remove_root_span(String.t(), keyword()) :: :ok
  def remove_root_span(span_id, opts \\ []) do
    table_name = Keyword.get(opts, :table_name, default_table_name())
    key = {:root_span, span_id}

    :ets.select_delete(table_name, [{{key, :_, :_}, [], [true]}])
    remove_child_spans(span_id, table_name: table_name)

    :ok
  end

  @spec remove_child_spans(String.t(), keyword()) :: :ok
  def remove_child_spans(parent_span_id, opts) do
    table_name = Keyword.get(opts, :table_name, default_table_name())

    :ets.select_delete(table_name, [
      {{{:child_span, parent_span_id, :_}, :_, :_}, [], [true]}
    ])

    :ok
  end

  defp schedule_cleanup(interval) do
    Process.send_after(self(), :cleanup_stale_spans, interval)
  end

  defp cleanup_stale_spans(table_name) do
    now = System.system_time(:second)
    cutoff_time = now - @span_ttl

    root_match_spec = [
      {{{:root_span, :"$1"}, :_, :"$2"}, [{:<, :"$2", cutoff_time}], [:"$1"]}
    ]

    expired_root_spans = :ets.select(table_name, root_match_spec)

    Enum.each(expired_root_spans, fn span_id ->
      remove_root_span(span_id, table_name: table_name)
    end)

    child_match_spec = [
      {{{:child_span, :_, :_}, :_, :"$1"}, [{:<, :"$1", cutoff_time}], [true]}
    ]

    :ets.select_delete(table_name, child_match_spec)
  end

  defp default_table_name do
    Module.concat(__MODULE__, ETSTable)
  end
end
