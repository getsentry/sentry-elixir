defmodule Sentry.ClientReports do
  use GenServer
  alias Sentry.Transport
  alias Sentry.Interfaces.ClientReport

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

  @send_interval 5000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_) do
    # check config to see if send_client_report is true
    GenServer.start_link(__MODULE__, %ClientReport{}, name: __MODULE__)
  end

  @spec add_discarded_event(String.t(), String.t()) :: :ok
  def add_discarded_event(type, reason) do
    GenServer.cast(__MODULE__, {:add_discarded_event, {type, reason}})
  end

  @impl true
  def init(state) do
    schedule_report()
    {:ok, state}
  end

  @impl true
  def handle_cast({:add_discarded_event, {type, reason}}, client_report) do
    if client_report.discarded_events == nil do
      {:noreply, %{client_report | discarded_events: %{{type, reason} => 1}}}
    else
      discarded_events = Map.update(client_report.discarded_events, {type, reason}, 1, &(&1 + 1))
      {:noreply, %{client_report | discarded_events: discarded_events}}
    end
  end

  @impl true
  def handle_info(:send_report, state) do
    if state.discarded_events != nil do
      IO.inspect(%{state | timestamp: timestamp()})
      # Create fn Transport.send_client_report(state) and send state with timestamp
      schedule_report()
      {:noreply, %ClientReport{}}
    else
      # state is nil so nothing to send but keep looping
      schedule_report()
      {:noreply, state}
    end
  end

  defp schedule_report do
    Process.send_after(self(), :send_report, @send_interval)
  end

  defp timestamp do
    DateTime.utc_now()
    |> DateTime.truncate(:microsecond)
    |> DateTime.to_iso8601()
    |> String.trim_trailing("Z")
  end
end
