defmodule Sentry.Metrics.Runtime do
  @moduledoc false

  # Reports BEAM runtime health as Sentry gauges.
  #
  # This is a plain `:telemetry` handler: it owns no process, no timer and no
  # supervision. Everything it reports is already measured and dispatched by
  # https://hexdocs.pm/telemetry_poller, whose application starts a default poller
  # emitting these events out of the box. Collection cadence is therefore the
  # poller's, configured with `config :telemetry_poller, default: [period: ...]`.

  alias Sentry.Metrics

  @handler_id "sentry-runtime-metrics"
  @origin "auto.elixir.runtime_metrics"

  @memory_event [:vm, :memory]
  @run_queue_event [:vm, :total_run_queue_lengths]
  @system_counts_event [:vm, :system_counts]

  @events [@memory_event, @run_queue_event, @system_counts_event]

  @run_queue_keys [:total, :cpu, :io]

  @system_counts [
    {"process", :process_count, :process_limit},
    {"atom", :atom_count, :atom_limit},
    {"port", :port_count, :port_limit}
  ]

  # Every key `:erlang.memory/0` reports, which is exactly what the poller measures.
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
    # `:telemetry.attach_many/4` returns {:error, :already_exists} and keeps the
    # *old* config, so detach first to survive a restart of the :sentry app.
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
    report(config, measurements, @memory_keys, "elixir.runtime.mem", "byte")
  end

  def handle_event(@run_queue_event, measurements, _metadata, config) do
    report(config, measurements, @run_queue_keys, "elixir.runtime.run_queue", nil)
  end

  def handle_event(@system_counts_event, measurements, _metadata, config) do
    Enum.each(@system_counts, fn {name, count_key, limit_key} ->
      report_count(config, name, measurements[count_key], measurements[limit_key])
    end)
  end

  defp report_count(_config, _name, nil, _limit), do: :ok

  defp report_count(config, name, count, limit) do
    gauge(config, "elixir.runtime.#{name}.count", count, nil)
    report_limit(config, name, count, limit)
  end

  # The limits only arrive from telemetry_poller 1.3.0 on, and the SDK allows
  # ~> 1.0 so that apps pinned to an older one still resolve.
  defp report_limit(_config, _name, _count, nil), do: :ok

  defp report_limit(config, name, count, limit) do
    gauge(config, "elixir.runtime.#{name}.limit", limit, nil)
    gauge(config, "elixir.runtime.#{name}.utilization", ratio(count, limit), "ratio")
  end

  defp ratio(_count, 0), do: 0.0
  defp ratio(count, limit), do: count / limit

  # Map.take/2 quietly skips keys the poller version at hand does not measure.
  defp report(config, measurements, keys, prefix, unit) do
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
