defmodule Sentry.Integrations.CheckInIDMappings do
  @moduledoc false

  use GenServer
  alias Sentry.UUID

  @table :sentry_cron_mappings

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link([] = _opts) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @spec lookup_or_insert_new(String.t()) :: UUID.t()
  def lookup_or_insert_new(key) do
    case :ets.lookup(@table, key) do
      [{^key, value}] ->
        value

      [] ->
        value = UUID.uuid4_hex()
        :ets.insert(@table, {key, value})
        value
    end
  end

  ## Callbacks

  @impl true
  def init(nil) do
    _table = :ets.new(@table, [:named_table, :public, :set])
    {:ok, :no_state}
  end
end
