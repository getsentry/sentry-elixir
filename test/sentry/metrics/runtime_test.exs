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
    test "reports one elixir.runtime.memory.used gauge in bytes per memory type" do
      metrics = emit_memory()

      assert Enum.all?(metrics, &(&1.name == "elixir.runtime.memory.used" and &1.unit == "byte"))

      assert memory_by_type(metrics) == %{
               "processes" => 40_000,
               "atom" => 1_000,
               "binary" => 5_000,
               "code" => 20_000,
               "ets" => 3_000,
               "other" => 31_000
             }
    end

    test "breaks the total down into types that sum back to it" do
      metrics = emit_memory()

      assert metrics |> memory_by_type() |> Map.values() |> Enum.sum() ==
               @memory_measurements.total
    end

    test "never reports a negative remainder when the named types exceed the total" do
      metrics =
        emit([:vm, :memory], %{
          total: 1_000,
          processes: 600,
          atom: 100,
          binary: 200,
          code: 100,
          ets: 100
        })

      assert memory_by_type(metrics)["other"] == 0
    end

    test "reports only the types the measurement lets it compute" do
      metrics = emit([:vm, :memory], %{total: 1_000, processes: 400, binary: 100})

      assert memory_by_type(metrics) == %{"processes" => 400, "binary" => 100}
    end
  end

  describe "run queue metrics" do
    test "reports one unitless elixir.runtime.run_queue.length gauge per run queue type" do
      metrics = emit([:vm, :total_run_queue_lengths], %{total: 7, cpu: 5, io: 2})

      assert Enum.all?(
               metrics,
               &(&1.name == "elixir.runtime.run_queue.length" and &1.unit == "none")
             )

      assert Map.new(metrics, &{&1.attributes["elixir.run_queue.type"], &1.value}) ==
               %{"cpu" => 5, "io" => 2}
    end
  end

  describe "system count metrics" do
    @system_counts %{
      process_count: 100,
      process_limit: 1_000,
      atom_count: 50,
      atom_limit: 500,
      port_count: 4,
      port_limit: 200
    }

    test "reports the unitless count and limit and the ratio between them" do
      metrics = emit([:vm, :system_counts], @system_counts)

      for {name, count, limit} <- [{"process", 100, 1_000}, {"atom", 50, 500}, {"port", 4, 200}] do
        assert %{value: ^count, unit: "none"} =
                 find_metric!(metrics, "elixir.runtime.#{name}.count")

        assert %{value: ^limit, unit: "none"} =
                 find_metric!(metrics, "elixir.runtime.#{name}.limit")

        utilization = find_metric!(metrics, "elixir.runtime.#{name}.utilization")
        assert utilization.value == count / limit
        assert utilization.unit == "ratio"
      end
    end

    test "omits the limit and the ratio when the poller does not report limits" do
      metrics = emit([:vm, :system_counts], %{process_count: 100})

      assert [%{name: "elixir.runtime.process.count", value: 100}] = metrics
    end
  end

  describe "scheduler utilization" do
    test "is not reported by the memory event" do
      metrics = emit_memory()

      refute "elixir.runtime.scheduler.utilization" in Enum.map(metrics, & &1.name)
    end

    test "reports nothing on the first measurement, which only takes a baseline" do
      attach()

      assert :ok = Runtime.dispatch_scheduler_utilization()
      flush_telemetry_processor()

      assert SentryTest.pop_sentry_metrics() == []
    end

    test "reports the busy fraction of scheduler time once a baseline exists" do
      attach()

      assert :ok = Runtime.dispatch_scheduler_utilization()
      assert :ok = Runtime.dispatch_scheduler_utilization()

      metric = assert_sentry_metric(:gauge, name: "elixir.runtime.scheduler.utilization")

      assert metric.unit == "ratio"
      assert metric.value >= 0.0 and metric.value <= 1.0
    end
  end

  describe "the scheduler poller" do
    test "follows the period configured for telemetry_poller" do
      put_telemetry_poller_default(period: 30_000)

      assert %{start: {:telemetry_poller, :start_link, [opts]}} = Runtime.child_spec([])
      assert opts[:period] == 30_000
    end

    test "leaves the period to telemetry_poller when none is configured" do
      put_telemetry_poller_default([])

      assert %{start: {:telemetry_poller, :start_link, [opts]}} = Runtime.child_spec([])
      refute Keyword.has_key?(opts, :period)
    end

    test "leaves the period to telemetry_poller when the default poller is disabled" do
      put_telemetry_poller_default(false)

      assert %{start: {:telemetry_poller, :start_link, [opts]}} = Runtime.child_spec([])
      refute Keyword.has_key?(opts, :period)
    end

    test "reports utilization when driven by a real poller" do
      attach()
      poller = start_supervised!(Runtime.child_spec([]))
      :ok = SentryTest.allow_sentry_reports(self(), poller)

      collect_once(poller)
      collect_once(poller)

      assert_sentry_metric(:gauge, name: "elixir.runtime.scheduler.utilization")
    end
  end

  describe "metric attributes" do
    @runtime_attributes [
      "process.runtime.name",
      "process.runtime.version",
      "process.runtime.engine.name",
      "process.runtime.engine.version"
    ]

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

    test "attaches the process.runtime attributes when version_attributes is enabled" do
      for metric <- emit_memory(version_attributes: true) do
        assert Map.take(metric.attributes, @runtime_attributes) == %{
                 "process.runtime.name" => "elixir",
                 "process.runtime.version" => System.version(),
                 "process.runtime.engine.name" => "BEAM",
                 "process.runtime.engine.version" =>
                   List.to_string(:erlang.system_info(:otp_release))
               }

        refute Map.has_key?(metric.attributes, "elixir_version")
        refute Map.has_key?(metric.attributes, "otp_release")
      end
    end

    test "omits the process.runtime attributes by default" do
      for metric <- emit_memory() do
        assert Map.take(metric.attributes, @runtime_attributes) == %{}
      end
    end
  end

  describe "wiring against a real telemetry_poller" do
    test "maps the builtin measurements onto Sentry gauges" do
      attach()

      poller = start_idle_poller([:memory, :total_run_queue_lengths, :system_counts])

      :ok = SentryTest.allow_sentry_reports(self(), poller)
      collect_once(poller)

      metric = assert_sentry_metric(:gauge, name: "elixir.runtime.memory.used")
      assert metric.value > 0

      assert_sentry_metric(:gauge, name: "elixir.runtime.run_queue.length")
      assert_sentry_metric(:gauge, name: "elixir.runtime.process.count")
      assert_sentry_metric(:gauge, name: "elixir.runtime.process.limit")
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

  defp put_telemetry_poller_default(value) do
    original = Application.get_env(:telemetry_poller, :default)
    Application.put_env(:telemetry_poller, :default, value)
    on_exit(fn -> Application.put_env(:telemetry_poller, :default, original) end)
  end

  defp memory_by_type(metrics) do
    metrics
    |> Enum.filter(&(&1.name == "elixir.runtime.memory.used"))
    |> Map.new(&{&1.attributes["elixir.memory.type"], &1.value})
  end

  defp find_metric!(metrics, name) do
    Enum.find(metrics, &(&1.name == name)) ||
      flunk("no #{name} in #{inspect(Enum.map(metrics, & &1.name))}")
  end
end
