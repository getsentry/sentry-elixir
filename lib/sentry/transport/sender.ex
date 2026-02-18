defmodule Sentry.Transport.Sender do
  @moduledoc false

  use GenServer

  alias Sentry.{Envelope, Event, Transport, Transaction}

  require Logger

  @registry Sentry.Transport.SenderRegistry

  ## Public API

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) when is_list(options) do
    index = Keyword.fetch!(options, :index)
    GenServer.start_link(__MODULE__, options, name: {:via, Registry, {@registry, index}})
  end

  @spec send_async(module(), Event.t()) :: :ok
  def send_async(client, %Event{} = event) when is_atom(client) do
    random_index = Enum.random(1..Transport.SenderPool.pool_size())
    counter_key = Transport.SenderPool.increase_queued_events_counter()

    GenServer.cast(
      {:via, Registry, {@registry, random_index}},
      {:send, client, event, counter_key}
    )
  end

  @spec send_async(module(), Transaction.t()) :: :ok
  def send_async(client, %Transaction{} = transaction) when is_atom(client) do
    random_index = Enum.random(1..Transport.SenderPool.pool_size())
    counter_key = Transport.SenderPool.increase_queued_transactions_counter()

    GenServer.cast(
      {:via, Registry, {@registry, random_index}},
      {:send, client, transaction, counter_key}
    )
  end

  ## State

  defstruct []

  ## Callbacks

  @impl GenServer
  def init(options) do
    if function_exported?(Process, :set_label, 1) do
      apply(Process, :set_label, [__MODULE__])
    end

    if rate_limiter_table_name = Keyword.get(options, :rate_limiter_table_name) do
      Process.put(:rate_limiter_table_name, rate_limiter_table_name)
    end

    {:ok, %__MODULE__{}}
  end

  @impl GenServer
  def handle_cast({:send, client, %Event{} = event, counter_key}, %__MODULE__{} = state) do
    retries = Application.get_env(:sentry, :request_retries, Transport.default_retries())

    _ =
      event
      |> Envelope.from_event()
      |> Transport.encode_and_post_envelope(client, retries)

    # We sent an event, so we can decrease the number of queued events.
    Transport.SenderPool.decrease_queued_events_counter(counter_key)

    {:noreply, state}
  end

  @impl GenServer
  def handle_cast(
        {:send, client, %Transaction{} = transaction, counter_key},
        %__MODULE__{} = state
      ) do
    retries = Application.get_env(:sentry, :request_retries, Transport.default_retries())

    _ =
      transaction
      |> Envelope.from_transaction()
      |> Transport.encode_and_post_envelope(client, retries)

    # We sent a transaction, so we can decrease the number of queued transactions.
    Transport.SenderPool.decrease_queued_transactions_counter(counter_key)

    {:noreply, state}
  end
end
