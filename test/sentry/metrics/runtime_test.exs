defmodule Sentry.Metrics.RuntimeTest do
  use Sentry.Case, async: false

  import ExUnit.CaptureLog
  import Sentry.TestHelpers

  alias Sentry.Metrics.Runtime

  setup do
    %{ref: ref} = Sentry.Test.setup_sentry(collect_envelopes: true)
    %{ref: ref}
  end

  describe "memory metrics" do
    test "reports memory gauges without any user code recording metrics", %{ref: ref} do
      collect_once()

      names = Enum.map(snapshot(ref), & &1["name"])

      assert "elixir.runtime.mem.total" in names
      assert "elixir.runtime.mem.processes" in names
      assert "elixir.runtime.mem.binary" in names
      assert "elixir.runtime.mem.ets" in names
      assert "elixir.runtime.mem.atom" in names
    end

    test "reports memory in bytes", %{ref: ref} do
      collect_once()

      assert metric = find_metric(snapshot(ref), "elixir.runtime.mem.total")
      assert metric["unit"] == "byte"
      assert metric["type"] == "gauge"
      assert metric["value"] > 0
    end
  end

  describe "version attributes" do
    test "attaches the Elixir and OTP versions to every metric", %{ref: ref} do
      collect_once()

      for metric <- snapshot(ref) do
        assert metric["attributes"]["elixir_version"]["value"] == System.version()

        assert metric["attributes"]["otp_release"]["value"] ==
                 List.to_string(:erlang.system_info(:otp_release))
      end
    end

    test "omits the version attributes when they are disabled", %{ref: ref} do
      collect_once(version_attributes: false)

      for metric <- snapshot(ref) do
        refute Map.has_key?(metric["attributes"], "elixir_version")
        refute Map.has_key?(metric["attributes"], "otp_release")
      end
    end
  end

  describe "scheduler utilization" do
    test "reports scheduler utilization as a ratio", %{ref: ref} do
      collect_once()

      assert metric = find_metric(snapshot(ref), "elixir.runtime.scheduler.utilization")
      assert metric["type"] == "gauge"
      assert metric["unit"] == "ratio"
      assert metric["value"] >= 0.0
      assert metric["value"] <= 1.0
    end
  end

  describe "run queue metrics" do
    test "reports total and CPU-bound run queue depth", %{ref: ref} do
      collect_once()

      metrics = snapshot(ref)

      assert total = find_metric(metrics, "elixir.runtime.run_queue.total")
      assert cpu = find_metric(metrics, "elixir.runtime.run_queue.cpu")

      assert total["type"] == "gauge"
      assert cpu["type"] == "gauge"
      assert total["value"] >= 0
      assert cpu["value"] >= 0
    end
  end

  describe "system limit metrics" do
    test "reports process, atom and port counts", %{ref: ref} do
      collect_once()

      names = Enum.map(snapshot(ref), & &1["name"])

      assert "elixir.runtime.process.count" in names
      assert "elixir.runtime.atom.count" in names
      assert "elixir.runtime.port.count" in names
    end

    test "reports each count against its VM limit", %{ref: ref} do
      collect_once()

      assert metric = find_metric(snapshot(ref), "elixir.runtime.process.count")

      limit = metric["attributes"]["limit"]["value"]
      ratio = metric["attributes"]["ratio"]["value"]

      assert limit >= metric["value"]
      assert_in_delta ratio, metric["value"] / limit, 0.0001
    end
  end

  describe "delivery" do
    test "delivers a whole snapshot from a single collection", %{ref: ref} do
      collect_once()

      assert length(snapshot(ref)) == 11
    end
  end

  describe "collection interval" do
    test "clamps an interval below the supported minimum" do
      log =
        capture_log(fn ->
          name = :"test_runtime_metrics_#{System.unique_integer([:positive])}"
          start_supervised!({Runtime, name: name, interval: 100}, id: name)
        end)

      assert log =~ "collection interval"
      assert log =~ "1000"
    end
  end

  defp collect_once(opts \\ []) do
    name = :"test_runtime_metrics_#{System.unique_integer([:positive])}"
    opts = Keyword.merge([name: name, interval: :timer.hours(1)], opts)

    pid = start_supervised!({Runtime, opts}, id: name)
    Sentry.Test.allow_sentry_reports(self(), pid)

    send(name, :tick)
    _ = :sys.get_state(name)

    :ok
  end

  defp snapshot(ref) do
    assert [%{"items" => items}] = collect_sentry_metric_items(ref, 1, timeout: 2000)
    items
  end

  defp find_metric(metrics, name) when is_list(metrics) do
    Enum.find(metrics, &(&1["name"] == name))
  end
end
