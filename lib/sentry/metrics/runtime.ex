defmodule Sentry.Metrics.Runtime do
  @moduledoc false

  use GenServer

  alias Sentry.LoggerUtils
  alias Sentry.Metrics
  alias Sentry.TelemetryProcessor

  @memory_gauges [:total, :processes, :binary, :ets, :atom]
  @min_interval 1_000

  defstruct [:interval, :attributes, :scheduler_sample]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    interval = normalize_interval(Keyword.fetch!(opts, :interval))
    attributes = version_attributes(Keyword.get(opts, :version_attributes, true))

    _ = :erlang.system_flag(:scheduler_wall_time, true)

    schedule_tick(interval)

    {:ok,
     %__MODULE__{
       interval: interval,
       attributes: attributes,
       scheduler_sample: scheduler_sample()
     }}
  end

  @impl true
  def handle_info(:tick, %__MODULE__{} = state) do
    state = collect_and_emit(state)
    schedule_tick(state.interval)
    {:noreply, state}
  end

  defp collect_and_emit(%__MODULE__{} = state) do
    sample = scheduler_sample()

    gauge(
      state,
      "elixir.runtime.scheduler.utilization",
      utilization(state.scheduler_sample, sample),
      unit: "ratio"
    )

    gauge(
      state,
      "elixir.runtime.run_queue.total",
      :erlang.statistics(:total_run_queue_lengths_all)
    )

    gauge(state, "elixir.runtime.run_queue.cpu", :erlang.statistics(:total_run_queue_lengths))

    memory = :erlang.memory()

    Enum.each(@memory_gauges, fn key ->
      gauge(state, "elixir.runtime.mem.#{key}", Keyword.fetch!(memory, key), unit: "byte")
    end)

    # A snapshot is a burst of a dozen metrics every interval, far below the
    # metric buffer's batch size, so without an explicit flush it would sit
    # buffered until unrelated telemetry happened to signal the scheduler.
    TelemetryProcessor.flush()

    %{state | scheduler_sample: sample}
  end

  defp scheduler_sample do
    case :erlang.statistics(:scheduler_wall_time) do
      :undefined -> []
      sample -> Enum.sort(sample)
    end
  end

  defp utilization(previous, current) do
    {active, total} =
      Enum.zip(previous, current)
      |> Enum.reduce({0, 0}, fn {{_, active0, total0}, {_, active1, total1}}, {active, total} ->
        {active + (active1 - active0), total + (total1 - total0)}
      end)

    if total > 0, do: active / total, else: 0.0
  end

  defp gauge(state, name, value, opts \\ [])

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
