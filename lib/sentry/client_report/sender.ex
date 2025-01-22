defmodule Sentry.ClientReport.Sender do
  @moduledoc false

  # This module is responsible for storing client reports and periodically "flushing"
  # them to Sentry.

  use GenServer

  alias Sentry.{Client, ClientReport, Config, Envelope}

  @send_interval 30_000

  @client_report_reasons ClientReport.reasons()

  @spec start_link([]) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, nil, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec record_discarded_events(atom(), [item], GenServer.server()) :: :ok
        when item:
               Sentry.Attachment.t()
               | Sentry.CheckIn.t()
               | ClientReport.t()
               | Sentry.Event.t()
               | Sentry.Transaction.t()
  def record_discarded_events(reason, event_items, genserver \\ __MODULE__)
      when is_list(event_items) do
    # We silently ignore events whose reasons aren't valid because we have to add it to the allowlist in Snuba
    # https://develop.sentry.dev/sdk/client-reports/
    if Enum.member?(@client_report_reasons, reason) do
      Enum.each(
        event_items,
        fn item ->
          GenServer.cast(
            genserver,
            {:record_discarded_events, reason, Envelope.get_data_category(item)}
          )
        end
      )
    end
  end

  ## Callbacks

  @impl true
  def init(nil) do
    schedule_report()
    {:ok, _state = %{}}
  end

  @impl true
  def handle_cast({:record_discarded_events, reason, category}, discarded_events) do
    {:noreply, Map.update(discarded_events, {reason, category}, 1, &(&1 + 1))}
  end

  @impl true
  def handle_info(:send_report, state) do
    _ =
      if map_size(state) != 0 and Config.dsn() != nil and Config.send_client_reports?() do
        client_report =
          %ClientReport{
            timestamp:
              DateTime.utc_now()
              |> DateTime.truncate(:second)
              |> DateTime.to_iso8601()
              |> String.trim_trailing("Z"),
            discarded_events:
              Enum.map(state, fn {{reason, category}, quantity} ->
                %{
                  reason: reason,
                  category: category,
                  quantity: quantity
                }
              end)
          }

        Client.send_client_report(client_report)
      end

    schedule_report()
    {:noreply, %{}}
  end

  defp schedule_report do
    Process.send_after(self(), :send_report, @send_interval)
  end
end
