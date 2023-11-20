defmodule Sentry.Dedupe do
  @moduledoc false

  use GenServer

  alias Sentry.Event

  @ets __MODULE__
  @sweep_interval_millisec 10_000
  @ttl_millisec 30_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    ttl_millisec = Keyword.get(opts, :ttl_millisec, @ttl_millisec)
    GenServer.start_link(__MODULE__, ttl_millisec, name: __MODULE__)
  end

  @spec insert(Event.t()) :: :new | :existing
  def insert(%Event{} = event) do
    hash = Event.hash(event)
    now = System.system_time(:millisecond)

    cond do
      _found? = :ets.update_element(@ets, hash, {_position = 2, now}) -> :existing
      _inserted_new? = :ets.insert_new(@ets, {hash, now}) -> :new
      true -> :existing
    end
  end

  ## State
  defstruct [:ttl_millisec]

  ## Callbacks

  @impl true
  def init(ttl_millisec) do
    _table = :ets.new(@ets, [:named_table, :public, :set])
    Process.send_after(self(), :sweep, @sweep_interval_millisec)
    {:ok, %__MODULE__{ttl_millisec: ttl_millisec}}
  end

  @impl true
  def handle_info(:sweep, %__MODULE__{} = state) do
    now = System.system_time(:millisecond)

    # All rows (which are {hash, inserted_at}) with an inserted_at older than
    # now - @ttl_millisec.
    match_spec = [{{:"$1", :"$2"}, [], [{:<, :"$2", now - state.ttl_millisec}]}]
    _ = :ets.select_delete(@ets, match_spec)

    Process.send_after(self(), :sweep, @sweep_interval_millisec)
    {:noreply, state}
  end
end
