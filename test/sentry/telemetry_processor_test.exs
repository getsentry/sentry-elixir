defmodule Sentry.TelemetryProcessorTest do
  use Sentry.Case, async: false

  alias Sentry.TelemetryProcessor
  alias Sentry.Telemetry.Buffer
  alias Sentry.Event
  alias Sentry.CheckIn
  alias Sentry.Transaction
  alias Sentry.LogEvent

  defp make_event(id) do
    %Event{event_id: id, timestamp: DateTime.utc_now()}
  end

  defp make_check_in(id) do
    %CheckIn{
      check_in_id: id,
      status: :ok,
      monitor_slug: "test-monitor"
    }
  end

  defp make_transaction(id) do
    now = DateTime.utc_now() |> DateTime.to_unix(:microsecond)

    %Transaction{
      event_id: id,
      span_id: "test-span-id",
      start_timestamp: now / 1_000_000,
      timestamp: now / 1_000_000,
      platform: "elixir",
      contexts: %{}
    }
  end

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
      assert length(children) == 6

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
          buffer_capacities: %{error: 50, log: 500}
        )

      error_buffer = TelemetryProcessor.get_buffer(pid, :error)
      state = :sys.get_state(error_buffer)
      assert state.capacity == 50

      Supervisor.stop(pid)
    end
  end

  describe "add/2" do
    test "routes Event to error buffer" do
      {:ok, pid} =
        TelemetryProcessor.start_link(
          name: :test_processor_add_event,
          buffer_configs: %{error: %{batch_size: 10}}
        )

      event = make_event("add-event-1")
      :ok = TelemetryProcessor.add(pid, event)

      Process.sleep(10)

      error_buffer = TelemetryProcessor.get_buffer(pid, :error)
      assert Buffer.size(error_buffer) == 1

      Supervisor.stop(pid)
    end

    test "routes CheckIn to check_in buffer" do
      {:ok, pid} =
        TelemetryProcessor.start_link(
          name: :test_processor_add_checkin,
          buffer_configs: %{check_in: %{batch_size: 10}}
        )

      check_in = make_check_in("add-checkin-1")
      :ok = TelemetryProcessor.add(pid, check_in)

      Process.sleep(10)

      check_in_buffer = TelemetryProcessor.get_buffer(pid, :check_in)
      assert Buffer.size(check_in_buffer) == 1

      Supervisor.stop(pid)
    end

    test "routes Transaction to transaction buffer" do
      {:ok, pid} =
        TelemetryProcessor.start_link(
          name: :test_processor_add_tx,
          buffer_configs: %{transaction: %{batch_size: 10}}
        )

      tx = make_transaction("add-tx-1")
      :ok = TelemetryProcessor.add(pid, tx)

      Process.sleep(10)

      tx_buffer = TelemetryProcessor.get_buffer(pid, :transaction)
      assert Buffer.size(tx_buffer) == 1

      Supervisor.stop(pid)
    end

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
          on_envelope: fn envelope -> send(test_pid, {:envelope, envelope}) end
        )

      event = make_event("signal-event")
      :ok = TelemetryProcessor.add(pid, event)

      assert_receive {:envelope, envelope}, 500
      assert envelope.event_id == "signal-event"

      Supervisor.stop(pid)
    end
  end

  describe "flush/2" do
    test "drains all buffers and sends envelopes" do
      test_pid = self()

      {:ok, pid} =
        TelemetryProcessor.start_link(
          name: :test_processor_flush,
          on_envelope: fn envelope -> send(test_pid, {:envelope, envelope}) end,
          buffer_configs: %{log: %{batch_size: 100}}
        )

      TelemetryProcessor.add(pid, make_event("flush-event"))
      TelemetryProcessor.add(pid, make_check_in("flush-checkin"))
      TelemetryProcessor.add(pid, make_log_event())

      receive_envelopes()

      :ok = TelemetryProcessor.flush(pid)

      for category <- [:error, :check_in, :transaction, :log] do
        buffer = TelemetryProcessor.get_buffer(pid, category)
        assert Buffer.size(buffer) == 0
      end

      Supervisor.stop(pid)
    end

    test "flush with timeout returns :ok" do
      test_pid = self()
      ref = make_ref()

      {:ok, pid} =
        TelemetryProcessor.start_link(
          name: :test_processor_flush_timeout,
          on_envelope: fn envelope -> send(test_pid, {ref, envelope}) end
        )

      TelemetryProcessor.add(pid, make_event("flush-timeout-event"))

      assert :ok = TelemetryProcessor.flush(pid, 5000)

      assert_receive {^ref, _envelope}, 1000

      Supervisor.stop(pid)
    end
  end

  describe "get_buffer/2" do
    test "returns buffer pid for each category" do
      {:ok, pid} = TelemetryProcessor.start_link(name: :test_processor_get_buffer)

      for category <- [:error, :check_in, :transaction, :log] do
        buffer = TelemetryProcessor.get_buffer(pid, category)
        assert is_pid(buffer)
        assert Process.alive?(buffer)
        assert Buffer.category(buffer) == category
      end

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
    test "flush drains buffers and transport queue" do
      test_pid = self()
      ref = make_ref()

      {:ok, pid} =
        TelemetryProcessor.start_link(
          name: :test_processor_flush_drain,
          on_envelope: fn envelope -> send(test_pid, {ref, envelope}) end,
          buffer_configs: %{log: %{batch_size: 100}}
        )

      TelemetryProcessor.add(pid, make_event("flush-drain-event"))
      TelemetryProcessor.add(pid, make_log_event())

      Process.sleep(50)
      flush_messages(ref)

      :ok = TelemetryProcessor.flush(pid)

      for category <- [:error, :check_in, :transaction, :log] do
        buffer = TelemetryProcessor.get_buffer(pid, category)
        assert Buffer.size(buffer) == 0
      end

      Supervisor.stop(pid)
    end

    test "get_queue_worker returns the queue worker pid" do
      {:ok, pid} = TelemetryProcessor.start_link(name: :test_processor_get_qw)

      queue_worker = TelemetryProcessor.get_queue_worker(pid)
      assert is_pid(queue_worker)
      assert Process.alive?(queue_worker)

      Supervisor.stop(pid)
    end

    test "respects transport_capacity option" do
      {:ok, pid} =
        TelemetryProcessor.start_link(
          name: :test_processor_capacity,
          transport_capacity: 42
        )

      queue_worker = TelemetryProcessor.get_queue_worker(pid)
      state = :sys.get_state(queue_worker)
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

  defp flush_messages(ref) do
    receive do
      {^ref, _} -> flush_messages(ref)
    after
      0 -> :ok
    end
  end
end
