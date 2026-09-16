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

  @events [@memory_event, @run_queue_event]

  @run_queue_keys [:total, :cpu, :io]

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
