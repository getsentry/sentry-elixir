defmodule Sentry.Metrics.Runtime do
  @moduledoc false

  use GenServer

  alias Sentry.LoggerUtils
  alias Sentry.Metrics

  @memory_gauges [:total, :processes, :binary, :ets, :atom]

  @origin "auto.elixir.runtime_metrics"

  defstruct [:interval, :attributes, :memory_available?, :normal_schedulers, :scheduler_sample]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    interval = Keyword.fetch!(opts, :interval)

    attributes =
      Map.merge(
        %{"sentry.origin" => @origin},
        version_attributes(Keyword.get(opts, :version_attributes, false))
      )

    _ = :erlang.system_flag(:scheduler_wall_time, true)

    schedule_tick(interval)

    normal_schedulers = :erlang.system_info(:schedulers)

    {:ok,
     %__MODULE__{
       interval: interval,
       attributes: attributes,
       memory_available?: memory_available?(),
       normal_schedulers: normal_schedulers,
       scheduler_sample: scheduler_sample(normal_schedulers)
     }}
  end

  @impl true
  def handle_info(:tick, %__MODULE__{} = state) do
    state = collect_and_emit(state)
    schedule_tick(state.interval)
    {:noreply, state}
  end

  defp collect_and_emit(%__MODULE__{} = state) do
    sample = scheduler_sample(state.normal_schedulers)

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

    if state.memory_available? do
      memory = :erlang.memory()

      Enum.each(@memory_gauges, fn key ->
        gauge(state, "elixir.runtime.mem.#{key}", Keyword.fetch!(memory, key), unit: "byte")
      end)
    end

    %{state | scheduler_sample: sample}
  end

  defp scheduler_sample(normal_schedulers) do
    case :erlang.statistics(:scheduler_wall_time) do
      :undefined ->
        []

      sample ->
        sample
        |> Enum.filter(fn {id, _active, _total} -> id <= normal_schedulers end)
        |> Enum.sort()
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

  defp memory_available? do
    _ = :erlang.memory()
    true
  rescue
    ErlangError ->
      LoggerUtils.warning(
        "[Sentry] runtime memory metrics are unavailable because this node was started with " <>
          "an erts_alloc allocator disabled; other runtime metrics are unaffected"
      )

      false
  end

  defp gauge(state, name, value, opts \\ [])

  defp gauge(%__MODULE__{} = state, name, value, opts) do
    Metrics.gauge(name, value, Keyword.put(opts, :attributes, state.attributes))
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
