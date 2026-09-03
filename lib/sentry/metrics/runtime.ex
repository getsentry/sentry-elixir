defmodule Sentry.Metrics.Runtime do
  @moduledoc false

  use GenServer

  alias Sentry.LoggerUtils
  alias Sentry.Metrics

  @memory_gauges [:total, :processes, :binary, :ets, :atom]

  @origin "auto.elixir.runtime_metrics"

  # The 30s default interval and this floor mirror DEFAULT_INTERVAL_MS and
  # MIN_COLLECTION_INTERVAL_MS in the JavaScript SDKs' runtime metrics integrations, so
  # collectors behave consistently across Sentry SDKs.
  @min_interval 1_000

  @system_limits [
    {"process", :process_count, :process_limit},
    {"atom", :atom_count, :atom_limit},
    {"port", :port_count, :port_limit}
  ]

  defstruct [
    :interval,
    :attributes,
    :memory_available?,
    :normal_schedulers,
    :scheduler_sample,
    :system_limits
  ]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    interval = normalize_interval(Keyword.fetch!(opts, :interval))

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
       scheduler_sample: scheduler_sample(normal_schedulers),
       system_limits: system_limits()
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

    Enum.each(state.system_limits, fn {name, count_key, limit} ->
      count = :erlang.system_info(count_key)

      gauge(state, "elixir.runtime.#{name}.count", count)
      gauge(state, "elixir.runtime.#{name}.limit", limit)

      gauge(state, "elixir.runtime.#{name}.utilization", utilization_of(count, limit),
        unit: "ratio"
      )
    end)

    %{state | scheduler_sample: sample}
  end

  # `:scheduler_wall_time` also reports dirty CPU schedulers, whose ids run above the normal
  # ones. They stay idle unless the application runs dirty NIFs, yet their wall time still
  # advances, so counting them roughly halves the reported utilization.
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

  # `:erlang.memory/0` raises `notsup` when an `erts_alloc` allocator was disabled at boot.
  # Allocator configuration is fixed for the lifetime of the VM, so this is probed once instead
  # of guarding every tick, and reported once so the missing gauges have a stated reason.
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

  # `+P`, `+t` and `+Q` fix these ceilings at VM boot, so they are read once.
  defp system_limits do
    Enum.map(@system_limits, fn {name, count_key, limit_key} ->
      {name, count_key, :erlang.system_info(limit_key)}
    end)
  end

  defp utilization_of(_count, 0), do: 0.0
  defp utilization_of(count, limit), do: count / limit

  defp gauge(state, name, value, opts \\ [])

  defp gauge(%__MODULE__{} = state, name, value, opts) do
    attributes = Map.merge(state.attributes, Keyword.get(opts, :attributes, %{}))
    Metrics.gauge(name, value, Keyword.put(opts, :attributes, attributes))
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
