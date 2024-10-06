defmodule Sentry.ClientReport do
  @moduledoc """
  **TODO** add proper doc for module

  See <https://develop.sentry.dev/sdk/client-reports/>.
  """

  @moduledoc since: "10.8.0"

  use GenServer
  alias Sentry.Client

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
  The struct for a **client report** interface.
  """
  @type t() :: %__MODULE__{
          timestamp: String.t() | number(),
          discarded_events: [%{reason: reason(), category: String.t(), quantity: pos_integer()}]
        }

  defstruct [:timestamp, discarded_events: %{}]

  @send_interval 5000

  @spec start_link([]) :: GenServer.on_start()
  def start_link([]) do
    # check config to see if send_client_report is true
    GenServer.start_link(__MODULE__, %__MODULE__{}, name: __MODULE__)
  end

  @spec add_discarded_event({reason(), String.t()}) :: :ok
  def add_discarded_event({reason, category}) do
    if Enum.member?(@client_report_reasons, reason) do
      GenServer.cast(__MODULE__, {:add_discarded_event, {reason, category}})
    end

    :ok
  end

  @impl true
  def init(state) do
    schedule_report()
    {:ok, state}
  end

  @impl true
  def handle_cast({:add_discarded_event, {reason, category}}, client_report) do
    if map_size(client_report.discarded_events) == 0 do
      {:noreply, %{client_report | discarded_events: %{{reason, category} => 1}}}
    else
      discarded_events =
        Map.update(client_report.discarded_events, {reason, category}, 1, &(&1 + 1))

      {:noreply, %__MODULE__{client_report | discarded_events: discarded_events}}
    end
  end

  @impl true
  def handle_info(:send_report, state) do
    if map_size(state.discarded_events) == 0 do
      updated_state = %{
        state
        | timestamp: timestamp(),
          discarded_events: transform_map(state.discarded_events)
      }

      _ = Client.send_client_report(updated_state)

      schedule_report()
      {:noreply, %__MODULE__{}}
    else
      # state is nil so nothing to send but keep looping
      schedule_report()
      {:noreply, %__MODULE__{}}
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

  defp transform_map(discarded_events_map) do
    discarded_events_map
    |> Enum.map(fn {{reason, category}, quantity} ->
      %{
        reason: reason,
        category: category,
        quantity: quantity
      }
    end)
  end
end
