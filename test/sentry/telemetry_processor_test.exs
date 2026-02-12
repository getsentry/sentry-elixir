defmodule Sentry.TelemetryProcessorTest do
  use Sentry.Case, async: false

  alias Sentry.TelemetryProcessor
  alias Sentry.Telemetry.Buffer
  alias Sentry.LogEvent

  defp make_log_event do
    %LogEvent{
      timestamp: System.system_time(:nanosecond) / 1_000_000_000,
      level: :info,
      body: "test log"
    }
  end

  describe "start_link/1" do
    test "starts the processor supervisor with all children" do
      {:ok, pid} = TelemetryProcessor.start_link(name: :test_processor_start)
      assert Process.alive?(pid)

      children = Supervisor.which_children(pid)
      # 2 buffers (error, log) + Scheduler = 3
      assert length(children) == 3

      Supervisor.stop(pid)
    end

    test "registers with given name" do
      {:ok, pid} = TelemetryProcessor.start_link(name: :test_processor_named)
      assert Process.whereis(:test_processor_named) == pid
      Supervisor.stop(pid)
    end

    test "accepts custom buffer capacities" do
      {:ok, pid} =
        TelemetryProcessor.start_link(
          name: :test_processor_capacities,
          buffer_capacities: %{log: 500}
        )

      log_buffer = TelemetryProcessor.get_buffer(pid, :log)
      state = :sys.get_state(log_buffer)
      assert state.capacity == 500

      Supervisor.stop(pid)
    end
  end

  describe "add/2" do
    test "routes LogEvent to log buffer" do
      {:ok, pid} = TelemetryProcessor.start_link(name: :test_processor_add_log)

      log = make_log_event()
      :ok = TelemetryProcessor.add(pid, log)

      Process.sleep(10)

      log_buffer = TelemetryProcessor.get_buffer(pid, :log)
      assert Buffer.size(log_buffer) == 1

      Supervisor.stop(pid)
    end

    test "signals scheduler when item added" do
      test_pid = self()

      {:ok, pid} =
        TelemetryProcessor.start_link(
          name: :test_processor_signal,
          on_envelope: fn envelope -> send(test_pid, {:envelope, envelope}) end,
          buffer_configs: %{log: %{batch_size: 1}}
        )

      :ok = TelemetryProcessor.add(pid, make_log_event())

      assert_receive {:envelope, envelope}, 500
      assert [%Sentry.LogBatch{log_events: [_]}] = envelope.items

      Supervisor.stop(pid)
    end
  end

  describe "flush/2" do
    test "drains log buffer and sends envelopes" do
      test_pid = self()

      {:ok, pid} =
        TelemetryProcessor.start_link(
          name: :test_processor_flush,
          on_envelope: fn envelope -> send(test_pid, {:envelope, envelope}) end,
          buffer_configs: %{log: %{batch_size: 100}}
        )

      TelemetryProcessor.add(pid, make_log_event())
      TelemetryProcessor.add(pid, make_log_event())
      TelemetryProcessor.add(pid, make_log_event())

      # Drain any messages from signal-triggered sends
      receive_envelopes()

      :ok = TelemetryProcessor.flush(pid)

      buffer = TelemetryProcessor.get_buffer(pid, :log)
      assert Buffer.size(buffer) == 0

      Supervisor.stop(pid)
    end

    test "flush with timeout returns :ok" do
      test_pid = self()
      ref = make_ref()

      {:ok, pid} =
        TelemetryProcessor.start_link(
          name: :test_processor_flush_timeout,
          on_envelope: fn envelope -> send(test_pid, {ref, envelope}) end,
          buffer_configs: %{log: %{batch_size: 1}}
        )

      TelemetryProcessor.add(pid, make_log_event())

      assert :ok = TelemetryProcessor.flush(pid, 5000)

      assert_receive {^ref, _envelope}, 1000

      Supervisor.stop(pid)
    end
  end

  describe "get_buffer/2" do
    test "returns buffer pid for log category" do
      {:ok, pid} = TelemetryProcessor.start_link(name: :test_processor_get_buffer)

      buffer = TelemetryProcessor.get_buffer(pid, :log)
      assert is_pid(buffer)
      assert Process.alive?(buffer)
      assert Buffer.category(buffer) == :log

      Supervisor.stop(pid)
    end
  end

  describe "get_scheduler/1" do
    test "returns scheduler pid" do
      {:ok, pid} = TelemetryProcessor.start_link(name: :test_processor_get_scheduler)

      scheduler = TelemetryProcessor.get_scheduler(pid)
      assert is_pid(scheduler)
      assert Process.alive?(scheduler)

      Supervisor.stop(pid)
    end
  end

  describe "integration" do
    test "respects transport_capacity option" do
      {:ok, pid} =
        TelemetryProcessor.start_link(
          name: :test_processor_capacity,
          transport_capacity: 42
        )

      scheduler = TelemetryProcessor.get_scheduler(pid)
      state = :sys.get_state(scheduler)
      assert state.capacity == 42

      Supervisor.stop(pid)
    end
  end

  defp receive_envelopes(acc \\ []) do
    receive do
      {:envelope, envelope} ->
        receive_envelopes([envelope | acc])
    after
      50 -> Enum.reverse(acc)
    end
  end
end
