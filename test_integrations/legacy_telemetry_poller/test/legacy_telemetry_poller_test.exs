defmodule LegacyTelemetryPollerTest do
  use ExUnit.Case, async: false

  alias Sentry.Test, as: SentryTest

  setup do
    SentryTest.setup_sentry()
  end

  test "runs against telemetry_poller 0.5 and telemetry 0.4" do
    assert [?0, ?., ?5, ?. | _] = Application.spec(:telemetry_poller, :vsn)
    assert [?0, ?., ?4, ?. | _] = Application.spec(:telemetry, :vsn)
  end

  test "reports runtime gauges from the builtin vm measurements" do
    poller =
      start_supervised!(
        {:telemetry_poller,
         [
           name: :legacy_vm_poller,
           period: :timer.hours(1),
           measurements: [:memory, :total_run_queue_lengths, :system_counts]
         ]}
      )

    names = poller |> collect_from() |> metric_names()

    assert "process.runtime.elixir.memory.used" in names
    assert "process.runtime.elixir.run_queue.length" in names
    assert "process.runtime.elixir.process.count" in names
    assert "process.runtime.elixir.atom.count" in names
    assert "process.runtime.elixir.port.count" in names
  end

  test "reports scheduler utilization from the poller Sentry starts" do
    poller = Process.whereis(Sentry.Metrics.Runtime)
    assert is_pid(poller)

    :ok = SentryTest.allow_sentry_reports(self(), poller)
    collect_once(poller)
    collect_once(poller)
    Sentry.TelemetryProcessor.flush()

    names = metric_names(SentryTest.pop_sentry_metrics())

    assert "process.runtime.elixir.scheduler.utilization" in names
  end

  defp collect_from(poller) do
    :ok = SentryTest.allow_sentry_reports(self(), poller)
    collect_once(poller)
    Sentry.TelemetryProcessor.flush()
    SentryTest.pop_sentry_metrics()
  end

  defp collect_once(poller) do
    send(poller, :collect)
    _ = :telemetry_poller.list_measurements(poller)
    :ok
  end

  defp metric_names(metrics), do: Enum.map(metrics, & &1.name)
end
