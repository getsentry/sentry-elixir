defmodule ProdMode.Callback do
  @moduledoc false

  # Test scaffolding for the prod_mode integration project. Every entry point
  # the Sentry SDK exposes for user-provided callbacks (`:before_send`,
  # `:before_send_log`, `:before_send_metric`) is wired to one of the
  # functions in this module. Each invocation appends to a named ETS table
  # which the test suite reads back to assert that callbacks were (or were
  # not) called.

  @table :prod_mode_callback_log

  @spec init_table() :: :ok
  def init_table do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :duplicate_bag])
    end

    :ok
  end

  @spec calls() :: [{atom(), term()}]
  def calls do
    :ets.tab2list(@table)
  end

  @spec reset() :: :ok
  def reset do
    :ets.delete_all_objects(@table)
    :ok
  end

  @spec on_event(term()) :: term()
  def on_event(event) do
    :ets.insert(@table, {:event, event})
    event
  end

  @spec on_log(term()) :: term()
  def on_log(log) do
    :ets.insert(@table, {:log, log})
    log
  end

  @spec on_metric(term()) :: term()
  def on_metric(metric) do
    :ets.insert(@table, {:metric, metric})
    metric
  end
end
