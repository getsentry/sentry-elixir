defmodule Sentry.Test.Registry do
  @moduledoc false

  use GenServer

  @table :sentry_test_collectors

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link([] = _opts) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @impl true
  def init(nil) do
    _table = :ets.new(@table, [:named_table, :public, :set])
    {:ok, :no_state}
  end
end
