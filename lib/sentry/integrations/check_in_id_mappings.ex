defmodule Sentry.Integrations.CheckInIDMappings do
  @moduledoc false

  use GenServer
  alias Sentry.UUID

  @table :sentry_cron_mappings
  @sweep_interval_millisec 30_000
  @ttl_millisec 10_000_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link([] = _opts) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @spec lookup_or_insert_new(String.t()) :: UUID.t()
  def lookup_or_insert_new(cron_key) do
    inserted_at = System.system_time(:millisecond)

    case :ets.lookup(@table, cron_key) do
      [{^cron_key, uuid, _inserted_at}] ->
        uuid

      [] ->
        uuid = UUID.uuid4_hex()
        :ets.insert(@table, {cron_key, uuid, inserted_at})
        uuid
    end
  end

  ## Callbacks

  @impl true
  def init(nil) do
    _table = :ets.new(@table, [:named_table, :public, :set])
    schedule_sweep()
    {:ok, :no_state}
  end

  @impl true
  def handle_info({:sweep, ttl_millisec}, state) do
    now = System.system_time(:millisecond)

    # All rows (which are {cron_key, uuid, inserted_at}) with an inserted_at older than
    # now - @ttl_millisec.
    match_spec = [{{:"$1", :"$2", :"$3"}, [], [{:<, :"$3", now - ttl_millisec}]}]
    _ = :ets.select_delete(@table, match_spec)

    schedule_sweep()
    {:noreply, state}
  end

  ## Helpers

  defp schedule_sweep do
    Process.send_after(self(), {:sweep, @ttl_millisec}, @sweep_interval_millisec)
  end
end

# Let's go with the GenServer that owns the table periodically sweeping it.
# Every ~30 seconds, it can send a message to itself, go through the all table and use ets:select_delete or
# something like that to remove all check-ins that are older than, say, 10 minutes.
# If needed we can add a timestamp to the check ins, I don't recall if we do that already.
