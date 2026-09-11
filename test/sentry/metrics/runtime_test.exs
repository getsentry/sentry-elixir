defmodule Sentry.Metrics.RuntimeTest do
  use Sentry.Case, async: false

  import ExUnit.CaptureLog
  import Sentry.TestHelpers

  alias Sentry.Metrics.Runtime

  @gauge_count 17
  @memory_gauge_count 5

  setup do
    Sentry.Test.setup_sentry(
      collect_envelopes: true,
      telemetry_processor: [buffer_configs: %{metric: %{batch_size: 1}}]
    )
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
    test "attaches the Elixir and OTP versions when enabled", %{ref: ref} do
      collect_once(version_attributes: true)

      for metric <- snapshot(ref) do
        assert metric["attributes"]["elixir_version"]["value"] == System.version()

        assert metric["attributes"]["otp_release"]["value"] ==
                 List.to_string(:erlang.system_info(:otp_release))
      end
    end

    test "omits the version attributes by default", %{ref: ref} do
      collect_once()

      for metric <- snapshot(ref) do
        refute Map.has_key?(metric["attributes"], "elixir_version")
        refute Map.has_key?(metric["attributes"], "otp_release")
      end
    end
  end

  describe "collector origin" do
    test "tags every metric with the runtime metrics origin", %{ref: ref} do
      collect_once()

      for metric <- snapshot(ref) do
        assert metric["attributes"]["sentry.origin"]["value"] == "auto.elixir.runtime_metrics"
      end
    end
  end

  describe "unsupported memory measurement" do
    test "skips only the memory gauges when memory cannot be measured", %{ref: ref} do
      pid = start_collector([])

      # `:erlang.memory/0` raises `notsup` on a VM booted with a disabled allocator, which
      # cannot be arranged from inside the test VM, so the probe result is planted instead.
      :sys.replace_state(pid, fn state -> %{state | memory_available?: false} end)

      send(pid, :tick)
      :sys.get_state(pid)

      names =
        ref
        |> collect_sentry_metric_items(@gauge_count - @memory_gauge_count, timeout: 2_000)
        |> Enum.flat_map(& &1["items"])
        |> Enum.map(& &1["name"])

      assert Process.alive?(pid)
      refute Enum.any?(names, &String.starts_with?(&1, "elixir.runtime.mem."))
      assert "elixir.runtime.scheduler.utilization" in names
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

    test "reports near-full utilization when every scheduler is busy", %{ref: ref} do
      pid = start_collector([])

      saturate_schedulers(400)
      send(pid, :tick)

      assert metric = find_metric(snapshot(ref), "elixir.runtime.scheduler.utilization")
      assert metric["value"] > 0.8
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

    test "reports each VM limit as its own gauge", %{ref: ref} do
      collect_once()

      metrics = snapshot(ref)

      assert count = find_metric(metrics, "elixir.runtime.process.count")
      assert limit = find_metric(metrics, "elixir.runtime.process.limit")

      assert limit["type"] == "gauge"
      assert limit["value"] >= count["value"]
    end

    test "reports utilization as the count over its limit", %{ref: ref} do
      collect_once()

      metrics = snapshot(ref)

      assert count = find_metric(metrics, "elixir.runtime.process.count")
      assert limit = find_metric(metrics, "elixir.runtime.process.limit")
      assert utilization = find_metric(metrics, "elixir.runtime.process.utilization")

      assert utilization["unit"] == "ratio"
      assert_in_delta utilization["value"], count["value"] / limit["value"], 0.0001
    end

    test "keeps varying values out of attributes so each metric stays one series", %{ref: ref} do
      collect_once()

      for metric <- snapshot(ref) do
        refute Map.has_key?(metric["attributes"], "limit")
        refute Map.has_key?(metric["attributes"], "ratio")
      end
    end
  end

  describe "delivery" do
    test "delivers a whole snapshot from a single collection", %{ref: ref} do
      collect_once()

      assert length(snapshot(ref)) == @gauge_count
    end

    test "continues collecting while an HTTP response is delayed", %{bypass: bypass} do
      owner = self()

      put_test_config(
        finch_request_opts: [receive_timeout: 10_000],
        before_send_metric: fn metric ->
          if metric.name == "elixir.runtime.mem.total", do: send(owner, :snapshot_collected)
          metric
        end
      )

      Bypass.stub(bypass, "POST", "/api/1/envelope/", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(owner, {:request_started, self(), body})

        receive do
          :release -> Plug.Conn.resp(conn, 200, ~s({"id":"accepted"}))
        after
          10_000 -> Plug.Conn.resp(conn, 500, "response was not released")
        end
      end)

      pid = start_collector(interval: 1_000)
      monitor = Process.monitor(pid)

      assert_receive :snapshot_collected, 2_000
      assert_receive {:request_started, handler, first_body}, 2_000

      try do
        assert_receive :snapshot_collected, 2_000
        assert Process.alive?(pid)
        refute_received {:DOWN, ^monitor, :process, ^pid, _}
      after
        stop_supervised!(Runtime)
        send(handler, :release)
      end

      assert_receive {:request_started, handler, second_body}, 2_000
      send(handler, :release)

      for body <- [first_body, second_body] do
        assert [%{"items" => items}] = extract_metric_items([decode_envelope!(body)])
        assert length(items) == 1
      end
    end
  end

  describe "delivery without an explicit flush" do
    setup do
      # Real batching: the gauges of one collection sit well below `batch_size`,
      # so only the buffer's own deadline can deliver them. The deadline is
      # shortened from the 5s default to keep the test quick.
      Sentry.Test.setup_telemetry_processor(
        buffer_configs: %{metric: %{batch_size: 100, timeout: 1_000}}
      )

      :ok
    end

    test "delivers a partial batch on the buffer deadline alone", %{ref: ref} do
      collect_once()

      items =
        ref
        |> collect_sentry_metric_items(1, timeout: 3_000)
        |> Enum.flat_map(& &1["items"])

      assert length(items) == @gauge_count
    end
  end

  describe "collection interval" do
    test "automatically delivers repeated snapshots at the configured interval", %{ref: ref} do
      start_collector(interval: 1_000)

      first = snapshot(ref)
      second = snapshot(ref)

      assert length(first) == @gauge_count
      assert length(second) == @gauge_count
      assert hd(second)["timestamp"] - hd(first)["timestamp"] >= 1.0
    end

    test "clamps an interval below the supported minimum", %{ref: ref} do
      log =
        capture_log(fn ->
          started_at = System.monotonic_time(:millisecond)
          start_collector(interval: 100)

          first = snapshot(ref)
          assert System.monotonic_time(:millisecond) - started_at >= 1_000
          second = snapshot(ref)
          assert hd(second)["timestamp"] - hd(first)["timestamp"] >= 1.0
        end)

      assert log =~ "collection interval"
      assert log =~ "1000"
    end
  end

  defp collect_once(opts \\ []) do
    pid = start_collector(opts)
    send(pid, :tick)
    :ok
  end

  defp start_collector(opts) do
    name = :"test_runtime_metrics_#{System.unique_integer([:positive])}"
    opts = Keyword.merge([name: name, interval: :timer.hours(1)], opts)

    pid = start_supervised!({Runtime, opts})
    Sentry.Test.allow_sentry_reports(self(), pid)
    pid
  end

  defp snapshot(ref) do
    ref
    |> collect_sentry_metric_items(@gauge_count, timeout: 2_000)
    |> Enum.flat_map(& &1["items"])
  end

  defp saturate_schedulers(duration_ms) do
    parent = self()

    pids =
      for _ <- 1..:erlang.system_info(:schedulers_online) do
        spawn(fn ->
          deadline = System.monotonic_time(:millisecond) + duration_ms

          spin = fn f ->
            if System.monotonic_time(:millisecond) < deadline, do: f.(f), else: :ok
          end

          spin.(spin)
          send(parent, {:spun, self()})
        end)
      end

    for pid <- pids, do: assert_receive({:spun, ^pid}, duration_ms * 10)
  end

  defp find_metric(metrics, name) when is_list(metrics) do
    Enum.find(metrics, &(&1["name"] == name))
  end
end
