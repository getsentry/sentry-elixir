defmodule Sentry.Sender do
  # @moduledoc false

  # use GenServer

  # alias Sentry.{Envelope, Event}

  # @registry Sentry.SenderRegistry

  # @async_queue_max_size 10
  # @async_queue_timeout 500

  # def start_link(options) when is_list(options) do
  #   index = Keyword.fetch!(options, :index)
  #   GenServer.start_link(__MODULE__, [], name: {:via, Registry, {@registry, index}})
  # end

  # def send_async(%Event{} = event) do
  #   pool_size = Application.fetch_env!(:sentry, :sender_pool_size)
  #   random_index = Enum.random(1..pool_size)

  #   GenServer.cast({:via, Registry, {@registry, random_index}}, {:send, event})
  # end

  # ## State

  # defstruct async_queue: :queue.new()

  # ## Callbacks

  # @impl true
  # def init([]) do
  #   Process.send_after(self(), :flush_async_queue, @async_queue_timeout)
  #   {:ok, %__MODULE__{}}
  # end

  # @impl true
  # def handle_call({:send, %Event{} = _event}, _from, %__MODULE__{} = state) do
  #   {:reply, raise("not implemented yet"), state}
  # end

  # @impl true
  # def handle_cast({:send, %Event{} = event}, %__MODULE__{} = state) do
  #   state = update_in(state.async_queue, &:queue.in(event, &1))

  #   state =
  #     if :queue.len(state.async_queue) >= @async_queue_max_size do
  #       flush_async_queue(state)
  #     else
  #       state
  #     end

  #   {:noreply, state}
  # end

  # @impl true
  # def handle_info(:flush_async_queue, %__MODULE__{} = state) do
  #   state = flush_async_queue(state)
  #   Process.send_after(self(), :flush_async_queue, @async_queue_timeout)
  #   {:noreply, state}
  # end

  # ## Helpers

  # defp flush_async_queue(%__MODULE__{} = state) do
  #   {events, state} = get_and_update_in(state.async_queue, &{&1, :queue.new()})

  #   envelope = Envelope.new(events)

  #   case Envelope.to_binary(envelope) do
  #     {:ok, binary} ->
  #       try_request(endpoint, auth_headers, {event, body}, Config.send_max_attempts())
  #       |> maybe_call_after_send_event(event)
  #       |> maybe_log_result(event)

  #     {:error, reason} ->
  #       IO.puts(
  #         :stderr,
  #         "Failed to encode Sentry events when trying to send them async: #{inspect(reason)} "
  #       )
  #   end

  #   state
  # end
end
