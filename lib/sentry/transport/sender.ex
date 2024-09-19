defmodule Sentry.Transport.Sender do
  @moduledoc false

  use GenServer

  alias Sentry.{Envelope, Event, Transport}

  require Logger

  @registry Sentry.Transport.SenderRegistry

  ## Public API

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) when is_list(options) do
    index = Keyword.fetch!(options, :index)
    GenServer.start_link(__MODULE__, [], name: {:via, Registry, {@registry, index}})
  end

  @spec send_async(module(), Event.t()) :: :ok
  def send_async(client, %Event{} = event) when is_atom(client) do
    random_index = Enum.random(1..Transport.SenderPool.pool_size())
    Transport.SenderPool.increase_queued_events_counter()
    GenServer.cast({:via, Registry, {@registry, random_index}}, {:send, client, event})
  end

  ## State

  defstruct []

  ## Callbacks

  @impl GenServer
  def init([]) do
    if function_exported?(Process, :set_label, 1) do
      apply(Process, :set_label, [__MODULE__])
    end

    {:ok, %__MODULE__{}}
  end

  @impl GenServer
  def handle_cast({:send, client, %Event{} = event}, %__MODULE__{} = state) do
    event
    |> Envelope.from_event()
    |> Transport.encode_and_post_envelope(client)

    # We sent an event, so we can decrease the number of queued events.
    Transport.SenderPool.decrease_queued_events_counter()

    {:noreply, state}
  end
end
