defmodule Sentry.Transport.Sender do
  @moduledoc false

  use GenServer

  alias Sentry.{Config, Envelope, Event, Transport}

  require Logger

  @registry Sentry.Transport.SenderRegistry

  @async_queue_max_size 10
  @async_queue_timeout 500

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) when is_list(options) do
    index = Keyword.fetch!(options, :index)
    GenServer.start_link(__MODULE__, [], name: {:via, Registry, {@registry, index}})
  end

  @spec send_async(Event.t()) :: :ok
  def send_async(%Event{} = event) do
    pool_size = Application.fetch_env!(:sentry, :sender_pool_size)
    random_index = Enum.random(1..pool_size)

    GenServer.cast({:via, Registry, {@registry, random_index}}, {:send, event})
  end

  ## State

  defstruct async_queue: :queue.new()

  ## Callbacks

  @impl true
  def init([]) do
    Process.send_after(self(), :flush_async_queue, @async_queue_timeout)
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_cast({:send, %Event{} = event}, %__MODULE__{} = state) do
    state = update_in(state.async_queue, &:queue.in(event, &1))

    state =
      if :queue.len(state.async_queue) >= @async_queue_max_size do
        flush_async_queue(state)
      else
        state
      end

    {:noreply, state}
  end

  @impl true
  def handle_info(:flush_async_queue, %__MODULE__{} = state) do
    state = flush_async_queue(state)
    Process.send_after(self(), :flush_async_queue, @async_queue_timeout)
    {:noreply, state}
  end

  ## Helpers

  defp flush_async_queue(%__MODULE__{async_queue: events_queue} = state) do
    if :queue.is_empty(events_queue) do
      state
    else
      events = :queue.to_list(events_queue)

      events
      |> Envelope.new()
      |> Transport.post_envelope()
      |> maybe_log_send_result(events)

      %__MODULE__{state | async_queue: :queue.new()}
    end
  end

  defp maybe_log_send_result(send_result, events) do
    if Enum.any?(events, &(&1.__source__ == :logger)) do
      :ok
    else
      message =
        case send_result do
          {:error, :invalid_dsn} ->
            "Cannot send Sentry event because of invalid DSN"

          {:error, {:invalid_json, error}} ->
            "Unable to encode JSON Sentry error - #{inspect(error)}"

          {:error, {:request_failure, last_error}} ->
            case last_error do
              {kind, data, stacktrace}
              when kind in [:exit, :throw, :error] and is_list(stacktrace) ->
                Exception.format(kind, data, stacktrace)

              _other ->
                "Error in HTTP Request to Sentry - #{inspect(last_error)}"
            end

          {:error, error} ->
            inspect(error)

          _ ->
            nil
        end

      if message do
        level = Config.log_level()
        Logger.log(level, fn -> ["Failed to send Sentry event. ", message] end, domain: [:sentry])
      end
    end
  end
end
