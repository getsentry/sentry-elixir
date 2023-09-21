defmodule Sentry.Transport.Sender do
  @moduledoc false

  use GenServer

  alias Sentry.{Config, Envelope, Event, Transport}

  require Logger

  @registry Sentry.Transport.SenderRegistry

  ## Public API

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

  defstruct []

  ## Callbacks

  @impl GenServer
  def init([]) do
    {:ok, %__MODULE__{}}
  end

  @impl GenServer
  def handle_cast({:send, %Event{} = event}, %__MODULE__{} = state) do
    [event]
    |> Envelope.new()
    |> Transport.post_envelope()
    |> maybe_log_send_result([event])

    {:noreply, state}
  end

  ## Helpers

  defp maybe_log_send_result(send_result, events) do
    if Enum.any?(events, &(&1.source == :logger)) do
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
