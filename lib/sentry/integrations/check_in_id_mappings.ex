defmodule Sentry.Integrations.CheckInIDMappings do
  @moduledoc false

  use GenServer
  alias Sentry.UUID

  @table :sentry_cron_mappings
  @sweep_interval_millisec 30_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    ttl_millisec = Keyword.get(opts, :max_expected_check_in_time)
    GenServer.start_link(__MODULE__, ttl_millisec, name: name)
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
  def init(ttl_millisec) do
    _table =
      if :ets.whereis(@table) == :undefined do
        :ets.new(@table, [:named_table, :public, :set])
      end

    schedule_sweep()
    {:ok, ttl_millisec}
  end

  @impl true
  def handle_info(:sweep, ttl_millisec) do
    now = System.system_time(:millisecond)
    # All rows (which are {cron_key, uuid, inserted_at}) with an inserted_at older than
    # now - ttl_millisec.
    match_spec = [{{:"$1", :"$2", :"$3"}, [], [{:<, :"$3", now - ttl_millisec}]}]
    _ = :ets.select_delete(@table, match_spec)

    schedule_sweep()
    {:noreply, ttl_millisec}
  end

  ## Helpers

  defp schedule_sweep() do
    Process.send_after(self(), :sweep, @sweep_interval_millisec)
  end
end
