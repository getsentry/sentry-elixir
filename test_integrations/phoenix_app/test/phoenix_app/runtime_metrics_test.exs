defmodule Sentry.Integrations.Phoenix.RuntimeMetricsTest do
  use PhoenixAppWeb.ConnCase, async: false

  import Sentry.TestHelpers

  alias Sentry.Test, as: SentryTest

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

  describe "memory metrics from a real telemetry_poller" do
    setup do
      SentryTest.setup_sentry(collect_envelopes: [type: "trace_metric"])
    end

    test "reports every key erlang:memory/0 measures as a gauge in bytes" do
      metrics = collect_runtime_metrics([:memory])

      for key <- @memory_keys do
        metric = find_metric!(metrics, "elixir.runtime.mem.#{key}")

        assert metric.value > 0
        assert metric.unit == "byte"
      end
    end

    test "delivers the gauges to Sentry as trace_metric envelope items", %{ref: ref} do
      [:memory] |> start_vm_poller() |> allow_and_collect()
      Sentry.TelemetryProcessor.flush()

      [batch] = collect_sentry_metric_items(ref, 1, timeout: 2000)
      item = Enum.find(batch["items"], &(&1["name"] == "elixir.runtime.mem.total"))

      assert item["type"] == "gauge"
      assert item["unit"] == "byte"
      assert item["value"] > 0
      assert item["attributes"]["sentry.origin"]["value"] == "auto.elixir.runtime_metrics"
    end
  end

  describe "the application wiring" do
    test "attaches the runtime metrics handler at boot" do
      handler_ids = [:vm, :memory] |> :telemetry.list_handlers() |> Enum.map(& &1.id)

      assert "sentry-runtime-metrics" in handler_ids
    end

    test "runs the default telemetry_poller the SDK relies on for its events" do
      assert is_pid(Process.whereis(:telemetry_poller_default))
    end
  end

  defp collect_runtime_metrics(measurements) do
    measurements |> start_vm_poller() |> allow_and_collect()
    Sentry.TelemetryProcessor.flush()

    metrics = SentryTest.pop_sentry_metrics()
    refute metrics == []
    metrics
  end

  defp start_vm_poller(measurements) do
    start_supervised!(
      {:telemetry_poller,
       [
         name: :"runtime_metrics_poller_#{System.unique_integer([:positive])}",
         init_delay: :timer.hours(1),
         period: :timer.hours(1),
         measurements: measurements
       ]}
    )
  end

  defp allow_and_collect(poller) do
    :ok = SentryTest.allow_sentry_reports(self(), poller)
    collect_once(poller)
  end

  defp collect_once(poller) do
    send(poller, :collect)
    _ = :telemetry_poller.list_measurements(poller)
    :ok
  end

  defp find_metric!(metrics, name) do
    Enum.find(metrics, &(&1.name == name)) ||
      flunk("no #{name} in #{inspect(Enum.map(metrics, & &1.name))}")
  end
end
