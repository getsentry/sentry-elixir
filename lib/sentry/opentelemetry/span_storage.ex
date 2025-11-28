if Sentry.OpenTelemetry.VersionChecker.tracing_compatible?() do
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

    @spec span_exists?(String.t(), keyword()) :: boolean()
    def span_exists?(span_id, opts \\ []) do
      table_name = Keyword.get(opts, :table_name, default_table_name())

      case :ets.lookup(table_name, {:root_span, span_id}) do
        [{{:root_span, ^span_id}, _span, _stored_at}] ->
          true

        [] ->
          case :ets.match_object(table_name, {{:child_span, :_, span_id}, :_, :_}) do
            [] -> false
            _ -> true
          end
      end
    end

    @spec store_span(SpanRecord.t(), keyword()) :: true
    def store_span(span_data, opts \\ []) do
      table_name = Keyword.get(opts, :table_name, default_table_name())
      stored_at = System.system_time(:second)

      if span_data.parent_span_id == nil do
        :ets.insert(table_name, {{:root_span, span_data.span_id}, span_data, stored_at})
      else
        key = {:child_span, span_data.parent_span_id, span_data.span_id}

        :ets.insert(table_name, {key, span_data, stored_at})
      end
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

      get_all_descendants(parent_span_id, table_name)
    end

    defp get_all_descendants(parent_span_id, table_name) do
      direct_children =
        :ets.match_object(table_name, {{:child_span, parent_span_id, :_}, :_, :_})
        |> Enum.map(fn {_key, span_data, _stored_at} -> span_data end)

      nested_descendants =
        Enum.flat_map(direct_children, fn child ->
          get_all_descendants(child.span_id, table_name)
        end)

      (direct_children ++ nested_descendants)
      |> Enum.sort_by(& &1.start_time)
    end

    @spec update_span(SpanRecord.t(), keyword()) :: :ok
    def update_span(%{parent_span_id: parent_span_id} = span_data, opts \\ []) do
      table_name = Keyword.get(opts, :table_name, default_table_name())
      stored_at = System.system_time(:second)

      key =
        if parent_span_id == nil do
          {:root_span, span_data.span_id}
        else
          {:child_span, parent_span_id, span_data.span_id}
        end

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

    @spec remove_child_span(String.t(), String.t(), keyword()) :: :ok
    def remove_child_span(parent_span_id, span_id, opts \\ []) do
      table_name = Keyword.get(opts, :table_name, default_table_name())
      key = {:child_span, parent_span_id, span_id}

      :ets.delete(table_name, key)

      :ok
    end

    # Pending children tracking functions
    #
    # These functions track spans that have started (on_start) but not yet ended (on_end).
    # This is crucial for handling the race condition where a parent span's on_end is called
    # before its child spans' on_end callbacks.
    #
    # The key insight is that when a child span starts, we record its existence in ETS.
    # When it ends, we remove the pending record. This allows us to:
    # 1. Know how many children are still in-flight when a parent ends
    # 2. Defer transaction building until all pending children have ended
    # 3. Have the last child trigger the transaction build

    @doc """
    Register a pending child span when it starts (via on_start callback).
    This creates a lightweight record tracking that a child span is in-flight.
    """
    @spec store_pending_child(String.t(), String.t(), keyword()) :: true
    def store_pending_child(parent_span_id, child_span_id, opts \\ []) do
      table_name = Keyword.get(opts, :table_name, default_table_name())
      stored_at = System.system_time(:second)

      key = {:pending_child, parent_span_id, child_span_id}
      :ets.insert(table_name, {key, stored_at})
    end

    @doc """
    Remove a pending child span when it ends (via on_end callback).
    """
    @spec remove_pending_child(String.t(), String.t(), keyword()) :: :ok
    def remove_pending_child(parent_span_id, child_span_id, opts \\ []) do
      table_name = Keyword.get(opts, :table_name, default_table_name())
      key = {:pending_child, parent_span_id, child_span_id}

      :ets.delete(table_name, key)
      :ok
    end

    @doc """
    Check if a span has any pending (in-flight) children.
    """
    @spec has_pending_children?(String.t(), keyword()) :: boolean()
    def has_pending_children?(parent_span_id, opts \\ []) do
      table_name = Keyword.get(opts, :table_name, default_table_name())

      case :ets.match_object(table_name, {{:pending_child, parent_span_id, :_}, :_}, 1) do
        {[_ | _], _} -> true
        :"$end_of_table" -> false
      end
    end

    @doc """
    Store a completed parent span that's waiting for its children to finish.
    This is used when a parent span ends but has pending children.
    """
    @spec store_waiting_parent(SpanRecord.t(), keyword()) :: true
    def store_waiting_parent(span_record, opts \\ []) do
      table_name = Keyword.get(opts, :table_name, default_table_name())
      stored_at = System.system_time(:second)

      key = {:waiting_parent, span_record.span_id}
      :ets.insert(table_name, {key, span_record, stored_at})
    end

    @doc """
    Get a waiting parent span by its span_id.
    """
    @spec get_waiting_parent(String.t(), keyword()) :: SpanRecord.t() | nil
    def get_waiting_parent(span_id, opts \\ []) do
      table_name = Keyword.get(opts, :table_name, default_table_name())

      case :ets.lookup(table_name, {:waiting_parent, span_id}) do
        [{{:waiting_parent, ^span_id}, span_record, _stored_at}] -> span_record
        [] -> nil
      end
    end

    @doc """
    Remove a waiting parent span after transaction has been built and sent.
    """
    @spec remove_waiting_parent(String.t(), keyword()) :: :ok
    def remove_waiting_parent(span_id, opts \\ []) do
      table_name = Keyword.get(opts, :table_name, default_table_name())
      :ets.delete(table_name, {:waiting_parent, span_id})
      :ok
    end

    @doc """
    Remove all pending children for a given parent span.
    Used during cleanup when a transaction is sent.
    """
    @spec remove_pending_children(String.t(), keyword()) :: :ok
    def remove_pending_children(parent_span_id, opts \\ []) do
      table_name = Keyword.get(opts, :table_name, default_table_name())

      :ets.select_delete(table_name, [
        {{{:pending_child, parent_span_id, :_}, :_}, [], [true]}
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

      # Cleanup stale pending children
      pending_child_match_spec = [
        {{{:pending_child, :_, :_}, :"$1"}, [{:<, :"$1", cutoff_time}], [true]}
      ]

      :ets.select_delete(table_name, pending_child_match_spec)

      # Cleanup stale waiting parents
      waiting_parent_match_spec = [
        {{{:waiting_parent, :_}, :_, :"$1"}, [{:<, :"$1", cutoff_time}], [true]}
      ]

      :ets.select_delete(table_name, waiting_parent_match_spec)
    end

    defp default_table_name do
      Module.concat(__MODULE__, ETSTable)
    end
  end
end
