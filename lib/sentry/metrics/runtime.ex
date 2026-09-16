defmodule Sentry.Metrics.Runtime do
  @moduledoc false

  alias Sentry.Metrics

  @compile {:no_warn_undefined, [:telemetry_poller]}

  @handler_id "sentry-runtime-metrics"
  @origin "auto.elixir.runtime_metrics"

  @memory_event [:vm, :memory]
  @run_queue_event [:vm, :total_run_queue_lengths]
  @system_counts_event [:vm, :system_counts]
  @scheduler_event [:sentry, :vm, :scheduler]
  @scheduler_sample_key {__MODULE__, :scheduler_sample}

  @events [@memory_event, @run_queue_event, @system_counts_event, @scheduler_event]

  @run_queue_keys [:total, :cpu, :io]

  @system_counts [
    {"process", :process_count, :process_limit},
    {"atom", :atom_count, :atom_limit},
    {"port", :port_count, :port_limit}
  ]

  @memory_keys [
    :total,
    :processes,
    :processes_used,
    :system,
    :atom,
    :atom_used,
    :binary,
    :code,
    :ets
  ]

  @spec attach(keyword()) :: :ok
  def attach(opts) when is_list(opts) do
    :ok = detach()

    _ = :telemetry.attach_many(@handler_id, @events, &__MODULE__.handle_event/4, config(opts))

    :ok
  end

  @spec detach() :: :ok
  def detach do
    _ = :telemetry.detach(@handler_id)
    :ok
  end

  @doc false
  @spec handle_event(
          :telemetry.event_name(),
          :telemetry.event_measurements(),
          :telemetry.event_metadata(),
          :telemetry.handler_config()
        ) :: :ok
  def handle_event(@memory_event, measurements, _metadata, config) do
    report_measured(config, measurements, @memory_keys, "elixir.runtime.mem", "byte")
  end

  def handle_event(@run_queue_event, measurements, _metadata, config) do
    report_measured(config, measurements, @run_queue_keys, "elixir.runtime.run_queue", nil)
  end

  def handle_event(@system_counts_event, measurements, _metadata, config) do
    Enum.each(@system_counts, fn {name, count_key, limit_key} ->
      report_count(config, name, measurements[count_key], measurements[limit_key])
    end)
  end

  def handle_event(@scheduler_event, %{utilization: utilization}, _metadata, config) do
    gauge(config, "elixir.runtime.scheduler.utilization", utilization, "ratio")
  end

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(_opts) do
    :telemetry_poller.child_spec(
      [name: __MODULE__, measurements: [{__MODULE__, :dispatch_scheduler_utilization, []}]] ++
        configured_poller_period()
    )
  end

  @doc false
  @spec dispatch_scheduler_utilization() :: :ok
  def dispatch_scheduler_utilization do
    case Process.get(@scheduler_sample_key) do
      nil ->
        _ = :erlang.system_flag(:scheduler_wall_time, true)
        Process.put(@scheduler_sample_key, scheduler_sample())

      previous ->
        current = scheduler_sample()
        Process.put(@scheduler_sample_key, current)
        dispatch_utilization(previous, current)
    end

    :ok
  end

  defp configured_poller_period do
    case Application.get_env(:telemetry_poller, :default, []) do
      opts when is_list(opts) -> Keyword.take(opts, [:period])
      _ -> []
    end
  end

  defp dispatch_utilization([], _current), do: :ok
  defp dispatch_utilization(_previous, []), do: :ok

  defp dispatch_utilization(previous, current) do
    {active, total} =
      previous
      |> Enum.zip(current)
      |> Enum.reduce({0, 0}, fn {{_, active0, total0}, {_, active1, total1}}, {active, total} ->
        {active + (active1 - active0), total + (total1 - total0)}
      end)

    :telemetry.execute(@scheduler_event, %{utilization: ratio(active, total)}, %{})
  end

  defp scheduler_sample do
    case :erlang.statistics(:scheduler_wall_time) do
      :undefined ->
        []

      sample ->
        normal_schedulers = :erlang.system_info(:schedulers)

        sample
        |> Enum.filter(fn {id, _active, _total} -> id <= normal_schedulers end)
        |> Enum.sort()
    end
  end

  defp report_count(_config, _name, nil, _limit), do: :ok

  defp report_count(config, name, count, limit) do
    gauge(config, "elixir.runtime.#{name}.count", count, nil)
    report_limit(config, name, count, limit)
  end

  defp report_limit(_config, _name, _count, nil), do: :ok

  defp report_limit(config, name, count, limit) do
    gauge(config, "elixir.runtime.#{name}.limit", limit, nil)
    gauge(config, "elixir.runtime.#{name}.utilization", ratio(count, limit), "ratio")
  end

  defp ratio(_count, 0), do: 0.0
  defp ratio(count, limit), do: count / limit

  defp report_measured(config, measurements, keys, prefix, unit) do
    Enum.each(Map.take(measurements, keys), fn {key, value} ->
      gauge(config, "#{prefix}.#{key}", value, unit)
    end)
  end

  defp config(opts) do
    attributes =
      Map.merge(
        %{"sentry.origin" => @origin},
        version_attributes(Keyword.get(opts, :version_attributes, false))
      )

    %{attributes: attributes}
  end

  defp version_attributes(false), do: %{}

  defp version_attributes(true) do
    %{
      "elixir_version" => System.version(),
      "otp_release" => List.to_string(:erlang.system_info(:otp_release))
    }
  end

  defp gauge(%{attributes: attributes}, name, value, unit) do
    Metrics.gauge(name, value, unit: unit, attributes: attributes)
  end
end
