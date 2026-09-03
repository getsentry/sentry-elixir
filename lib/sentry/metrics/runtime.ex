defmodule Sentry.Metrics.Runtime do
  @moduledoc false

  use GenServer

  alias Sentry.LoggerUtils
  alias Sentry.Metrics
  alias Sentry.TelemetryProcessor

  @memory_gauges [:total, :processes, :binary, :ets, :atom]
  @min_interval 1_000

  defstruct [:interval, :attributes]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    interval = normalize_interval(Keyword.fetch!(opts, :interval))
    attributes = version_attributes(Keyword.get(opts, :version_attributes, true))

    schedule_tick(interval)

    {:ok, %__MODULE__{interval: interval, attributes: attributes}}
  end

  @impl true
  def handle_info(:tick, %__MODULE__{} = state) do
    collect_and_emit(state)
    schedule_tick(state.interval)
    {:noreply, state}
  end

  defp collect_and_emit(%__MODULE__{} = state) do
    memory = :erlang.memory()

    Enum.each(@memory_gauges, fn key ->
      gauge(state, "elixir.runtime.mem.#{key}", Keyword.fetch!(memory, key), unit: "byte")
    end)

    # A snapshot is a burst of a dozen metrics every interval, far below the
    # metric buffer's batch size, so without an explicit flush it would sit
    # buffered until unrelated telemetry happened to signal the scheduler.
    TelemetryProcessor.flush()
  end

  defp gauge(%__MODULE__{} = state, name, value, opts) do
    Metrics.gauge(name, value, Keyword.put(opts, :attributes, state.attributes))
  end

  defp normalize_interval(interval) when is_integer(interval) and interval >= @min_interval do
    interval
  end

  defp normalize_interval(interval) do
    LoggerUtils.warning(
      "[Sentry] runtime metrics collection interval of #{inspect(interval)}ms is below the " <>
        "supported minimum, falling back to #{@min_interval}ms"
    )

    @min_interval
  end

  defp version_attributes(false), do: %{}

  defp version_attributes(true) do
    %{
      elixir_version: System.version(),
      otp_release: List.to_string(:erlang.system_info(:otp_release))
    }
  end

  defp schedule_tick(interval), do: Process.send_after(self(), :tick, interval)
end
