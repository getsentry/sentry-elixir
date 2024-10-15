defmodule Sentry.ClientReport do
  @moduledoc """
  **TODO** add proper doc for module

  See <https://develop.sentry.dev/sdk/client-reports/>.
  """

  @moduledoc since: "10.8.0"

  use GenServer
  alias Sentry.{Client, Config, Envelope}

  @client_report_reasons [
    :ratelimit_backoff,
    :queue_overflow,
    :cache_overflow,
    :network_error,
    :sample_rate,
    :before_send,
    :event_processor,
    :insufficient_data,
    :backpressure,
    :send_error,
    :internal_sdk_error
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
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc false
  @spec record_discarded_events(
          reason(),
          [item]
        ) :: :ok
        when item:
               Sentry.Attachment.t()
               | Sentry.CheckIn.t()
               | Sentry.ClientReport.t()
               | Sentry.Event.t()
  def record_discarded_events(reason, event_items, genserver \\ __MODULE__)
      when is_list(event_items) do
    if Enum.member?(@client_report_reasons, reason) do
      _ =
        event_items
        |> Enum.each(
          &GenServer.cast(
            genserver,
            {:record_discarded_events, reason, Envelope.get_data_category(&1)}
          )
        )
    end

    # We silently ignore events whose reasons aren't valid because we have to add it to the allowlist in Snuba
    # https://develop.sentry.dev/sdk/client-reports/

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
  def handle_cast({:record_discarded_events, reason, category}, discarded_events) do
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
