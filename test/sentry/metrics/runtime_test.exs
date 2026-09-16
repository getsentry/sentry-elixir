defmodule Sentry.Metrics.RuntimeTest do
  use Sentry.Case, async: false

  import Sentry.Test.Assertions
  import Sentry.TestHelpers

  alias Sentry.Metrics.Runtime
  alias Sentry.Test, as: SentryTest

  @memory_measurements %{
    total: 100_000,
    processes: 40_000,
    processes_used: 39_000,
    system: 60_000,
    atom: 1_000,
    atom_used: 900,
    binary: 5_000,
    code: 20_000,
    ets: 3_000
  }

  setup do
    SentryTest.setup_sentry()
  end

  describe "memory metrics" do
    test "reports every key of the measurement map as a gauge in bytes" do
      metrics = emit_memory()

      for {key, value} <- @memory_measurements do
        metric = find_metric!(metrics, "elixir.runtime.mem.#{key}")

        assert metric.value == value
        assert metric.unit == "byte"
      end
    end

    test "skips keys the measurement map does not carry" do
      metrics = emit([:vm, :memory], %{total: 1})

      assert [%{name: "elixir.runtime.mem.total"}] = metrics
    end
  end

  describe "run queue metrics" do
    test "reports the run queue lengths as unitless gauges" do
      metrics = emit([:vm, :total_run_queue_lengths], %{total: 7, cpu: 5, io: 2})

      for {key, value} <- [total: 7, cpu: 5, io: 2] do
        metric = find_metric!(metrics, "elixir.runtime.run_queue.#{key}")

        assert metric.value == value
        assert metric.unit == nil
      end
    end
  end

  describe "metric attributes" do
    test "tags every metric with the runtime metrics origin" do
      for metric <- emit_memory() do
        assert metric.attributes["sentry.origin"] == "auto.elixir.runtime_metrics"
      end
    end

    test "names every metric under the elixir.runtime namespace" do
      for metric <- emit_memory() do
        assert String.starts_with?(metric.name, "elixir.runtime.")
      end
    end

    test "attaches the Elixir and OTP versions when version_attributes is enabled" do
      for metric <- emit_memory(version_attributes: true) do
        assert metric.attributes["elixir_version"] == System.version()

        assert metric.attributes["otp_release"] ==
                 List.to_string(:erlang.system_info(:otp_release))
      end
    end

    test "omits the version attributes by default" do
      for metric <- emit_memory() do
        refute Map.has_key?(metric.attributes, "elixir_version")
        refute Map.has_key?(metric.attributes, "otp_release")
      end
    end
  end

  describe "wiring against a real telemetry_poller" do
    test "maps the builtin measurements onto Sentry gauges" do
      attach()
      poller = start_idle_poller([:memory, :total_run_queue_lengths])

      :ok = SentryTest.allow_sentry_reports(self(), poller)
      collect_once(poller)

      metric = assert_sentry_metric(:gauge, name: "elixir.runtime.mem.total")
      assert metric.value > 0

      assert_sentry_metric(:gauge, name: "elixir.runtime.run_queue.total")
    end
  end

  defp emit_memory(opts \\ []), do: emit([:vm, :memory], @memory_measurements, opts)

  defp emit(event, measurements, opts \\ []) do
    attach(opts)
    :telemetry.execute(event, measurements, %{})
    flush_telemetry_processor()

    metrics = SentryTest.pop_sentry_metrics()
    refute metrics == []
    metrics
  end

  defp attach(opts \\ []) do
    :ok = Runtime.attach(opts)
    on_exit(&Runtime.detach/0)
  end

  defp start_idle_poller(measurements) do
    start_supervised!(
      {:telemetry_poller,
       [
         name: :"test_poller_#{System.unique_integer([:positive])}",
         init_delay: :timer.hours(1),
         period: :timer.hours(1),
         measurements: measurements
       ]}
    )
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
