defmodule Sentry.Integrations.CheckInIDMappings do
  @moduledoc false

  use GenServer

  @table :cron

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link([] = _opts) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @spec lookup(String.t()) :: {:ok, <<_::256>>}
  def lookup(key) do
    case :ets.lookup(@table, key) do
      [{^key, value}] ->
        {:ok, value}

      [] ->
        value = Sentry.UUID.uuid4_hex()
        :ets.insert(@table, {key, value})
        {:ok, value}
    end
  end

  ## Callbacks

  @impl true
  def init(nil) do
    _table = :ets.new(@table, [:named_table, :public, :set])
    {:ok, :no_state}
  end
end
