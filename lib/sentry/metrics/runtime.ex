defmodule Sentry.Metrics.Runtime do
  @moduledoc false

  alias Sentry.Metrics

  @handler_id "sentry-runtime-metrics"
  @origin "auto.elixir.runtime_metrics"

  @memory_event [:vm, :memory]

  @events [@memory_event]

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
