defmodule Sentry.Transport.Sender do
  @moduledoc false

  use GenServer

  alias Sentry.{Envelope, Event, Transport, Transaction, LoggerUtils}

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

  @spec send_async(module(), Transaction.t()) :: :ok
  def send_async(client, %Transaction{} = transaction) when is_atom(client) do
    random_index = Enum.random(1..Transport.SenderPool.pool_size())
    Transport.SenderPool.increase_queued_transactions_counter()
    GenServer.cast({:via, Registry, {@registry, random_index}}, {:send, client, transaction})
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
    _ =
      event
      |> Envelope.from_event()
      |> Transport.encode_and_post_envelope(client)

    # We sent an event, so we can decrease the number of queued events.
    Transport.SenderPool.decrease_queued_events_counter()

    {:noreply, state}
  end

  @impl GenServer
  def handle_cast({:send, client, %Transaction{} = transaction}, %__MODULE__{} = state) do
    envelope = Envelope.from_transaction(transaction)

    envelope
    |> Transport.encode_and_post_envelope(client)
    |> maybe_log_send_result([transaction])

    # We sent an event, so we can decrease the number of queued events.
    Transport.SenderPool.decrease_queued_events_counter()

    {:noreply, state}
  end

  ## Helpers

  defp maybe_log_send_result(send_result, events) do
    if Enum.any?(events, fn item ->
         case item do
           %Event{} -> item.source == :logger
           _ -> false
         end
       end) do
      :ok
    else
      message =
        case send_result do
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

          {:error, http_reponse} ->
            {status, headers, _body} = http_reponse

            error_header =
              :proplists.get_value("X-Sentry-Error", headers, nil) ||
                :proplists.get_value("x-sentry-error", headers, nil) || ""

            if error_header != "" do
              "Received #{status} from Sentry server: #{error_header}"
            else
              "Received #{status} from Sentry server"
            end

          result ->
            result
        end

      if message do
        LoggerUtils.log(fn -> ["Failed to send Sentry event. ", message] end)
      end
    end
  end
end
