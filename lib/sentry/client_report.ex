defmodule Sentry.ClientReport do
  @moduledoc """
  **TODO** add proper doc for module

  See <https://develop.sentry.dev/sdk/client-reports/>.
  """

  @moduledoc since: "10.8.0"

  use GenServer
  alias Sentry.{Client, Config}

  @client_report_reasons [
    :ratelimit_backoff,
    :queue_overflow,
    :cache_overflow,
    :network_error,
    :sample_rate,
    :before_send,
    :event_processor,
    :insufficient_data,
    :backpressure
  ]

  @typedoc """
  The possible reasons of the discarded event.
  """
  @type reason() ::
          unquote(Enum.reduce(@client_report_reasons, &quote(do: unquote(&1) | unquote(&2))))

  @typedoc """
  The struct for a **client report**.
  """
  @type t() :: %__MODULE__{
          timestamp: String.t() | number(),
          discarded_events: [%{reason: reason(), category: String.t(), quantity: pos_integer()}]
        }

  defstruct [:timestamp, discarded_events: %{}]

  @send_interval 30_000

  @doc false
  @spec start_link([]) :: GenServer.on_start()
  def start_link([]) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @spec add_discarded_event(reason(), String.t()) :: :ok
  def add_discarded_event(reason, category) do
    if Enum.member?(@client_report_reasons, reason) do
      GenServer.cast(__MODULE__, {:add_discarded_event, reason, category})
    end

    :ok
  end

  @doc false
  @impl true
  def init(state) do
    schedule_report()
    {:ok, state}
  end

  @doc false
  @impl true
  def handle_cast({:add_discarded_event, reason, category}, discarded_events) do
    {:noreply, Map.update(discarded_events, {reason, category}, 1, &(&1 + 1))}
  end

  @doc false
  @impl true
  def handle_info(:send_report, discarded_events) do
    if map_size(discarded_events) != 0 do
      discarded_events =
        discarded_events
        |> Enum.map(fn {{reason, category}, quantity} ->
          %{
            reason: reason,
            category: category,
            quantity: quantity
          }
        end)

      client_report =
        %__MODULE__{
          timestamp: timestamp(),
          discarded_events: discarded_events
        }

      _ =
        if Config.dsn() != nil && Config.send_client_reports?() do
          Client.send_client_report(client_report)
        end

      schedule_report()
      {:noreply, %{}}
    else
      # state is nil so nothing to send but keep looping
      schedule_report()
      {:noreply, %{}}
    end
  end

  defp schedule_report do
    Process.send_after(self(), :send_report, @send_interval)
  end

  defp timestamp do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
    |> String.trim_trailing("Z")
  end
end
