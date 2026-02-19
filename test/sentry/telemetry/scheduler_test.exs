defmodule Sentry.Telemetry.SchedulerTest do
  use Sentry.Case, async: false

  import ExUnit.CaptureLog
  import Sentry.TestHelpers

  alias Sentry.Telemetry.{Buffer, Scheduler}
  alias Sentry.LogEvent

  defp make_log_event(body \\ "test log") do
    %LogEvent{
      timestamp: System.system_time(:nanosecond) / 1_000_000_000,
      level: :info,
      body: body
    }
  end

  describe "build_priority_cycle/0" do
    test "builds cycle with correct weights for all categories" do
      cycle = Scheduler.build_priority_cycle()

      # Default weights: critical=5, high=4, medium=3, low=2
      assert length(cycle) == 14
      assert Enum.frequencies(cycle) == %{error: 5, check_in: 4, transaction: 3, log: 2}
    end

    test "builds cycle with custom weights" do
      custom_weights = %{low: 5}
      cycle = Scheduler.build_priority_cycle(custom_weights)

      assert length(cycle) == 17
      assert Enum.frequencies(cycle) == %{error: 5, check_in: 4, transaction: 3, log: 5}
    end
  end

  describe "start_link/1" do
    test "starts scheduler with buffers" do
      buffers = start_test_buffers()

      {:ok, pid} =
        Scheduler.start_link(
          buffers: buffers,
          name: :test_scheduler_start
        )

      assert Process.alive?(pid)
      GenServer.stop(pid)
      stop_buffers(buffers)
    end

    test "accepts custom weights" do
      buffers = start_test_buffers()

      {:ok, pid} =
        Scheduler.start_link(
          buffers: buffers,
          weights: %{low: 5},
          name: :test_scheduler_weights
        )

      state = :sys.get_state(pid)
      # Only log buffer provided, so cycle is filtered to log only with weight 5
      assert length(state.priority_cycle) == 5
      GenServer.stop(pid)
      stop_buffers(buffers)
    end
  end

  describe "signal/1" do
    test "wakes scheduler to process log items" do
      buffers = start_test_buffers(batch_size: 1)
      test_pid = self()

      {:ok, pid} =
        Scheduler.start_link(
          buffers: buffers,
          on_envelope: fn envelope -> send(test_pid, {:envelope, envelope}) end,
          name: :test_scheduler_signal
        )

      Buffer.add(buffers.log, make_log_event())
      Scheduler.signal(pid)

      assert_receive {:envelope, envelope}, 500
      assert [%Sentry.LogBatch{log_events: events}] = envelope.items
      assert length(events) == 1

      GenServer.stop(pid)
      stop_buffers(buffers)
    end
  end

  describe "envelope building" do
    test "batches log events into single envelope" do
      buffers = start_test_buffers(batch_size: 2)
      test_pid = self()

      {:ok, pid} =
        Scheduler.start_link(
          buffers: buffers,
          on_envelope: fn envelope -> send(test_pid, {:envelope, envelope}) end,
          name: :test_scheduler_log_batch
        )

      # Add two log events (batch size = 2)
      Buffer.add(buffers.log, make_log_event())
      Buffer.add(buffers.log, make_log_event())
      Scheduler.signal(pid)

      assert_receive {:envelope, envelope}, 500
      # Logs are batched into LogBatch
      assert [%Sentry.LogBatch{log_events: events}] = envelope.items
      assert length(events) == 2

      GenServer.stop(pid)
      stop_buffers(buffers)
    end
  end

  describe "flush/1" do
    test "drains log buffer and sends envelopes" do
      buffers = start_test_buffers(batch_size: 100)
      test_pid = self()

      {:ok, pid} =
        Scheduler.start_link(
          buffers: buffers,
          on_envelope: fn envelope -> send(test_pid, {:envelope, envelope}) end,
          name: :test_scheduler_flush
        )

      # Add items without signaling
      Buffer.add(buffers.log, make_log_event())
      Buffer.add(buffers.log, make_log_event())
      Buffer.add(buffers.log, make_log_event())

      # Flush should drain everything
      :ok = Scheduler.flush(pid)

      # Should receive an envelope with all logs batched
      envelopes = receive_envelopes_until_empty()
      assert length(envelopes) == 1

      [envelope] = envelopes
      assert [%Sentry.LogBatch{log_events: events}] = envelope.items
      assert length(events) == 3

      # Buffer should be empty
      assert Buffer.size(buffers.log) == 0

      GenServer.stop(pid)
      stop_buffers(buffers)
    end
  end

  describe "before_send_log callback error protection" do
    test "callback that raises still allows events to be processed" do
      buffers = start_test_buffers(batch_size: 1)
      test_pid = self()

      put_test_config(
        before_send_log: fn _log_event ->
          raise "boom"
        end
      )

      {:ok, pid} =
        Scheduler.start_link(
          buffers: buffers,
          on_envelope: fn envelope -> send(test_pid, {:envelope, envelope}) end,
          name: :"test_scheduler_raise_#{System.unique_integer([:positive])}"
        )

      log =
        capture_log(fn ->
          Buffer.add(buffers.log, make_log_event("test"))
          Scheduler.signal(pid)

          assert_receive {:envelope, envelope}, 500
          # Event passes through unmodified when callback raises
          assert [%Sentry.LogBatch{log_events: [%LogEvent{body: "test"}]}] = envelope.items
        end)

      assert log =~ "before_send_log callback failed"

      GenServer.stop(pid)
      stop_buffers(buffers)
    end

    test "callback that raises does not crash the Scheduler" do
      buffers = start_test_buffers(batch_size: 1)
      test_pid = self()

      put_test_config(
        before_send_log: fn _log_event ->
          raise "boom"
        end
      )

      {:ok, pid} =
        Scheduler.start_link(
          buffers: buffers,
          on_envelope: fn envelope -> send(test_pid, {:envelope, envelope}) end,
          name: :"test_scheduler_survive_#{System.unique_integer([:positive])}"
        )

      capture_log(fn ->
        Buffer.add(buffers.log, make_log_event("first"))
        Scheduler.signal(pid)
        assert_receive {:envelope, _}, 500
      end)

      # Scheduler is still alive and functional
      assert Process.alive?(pid)

      # Can still process new events
      put_test_config(before_send_log: fn log_event -> log_event end)

      Buffer.add(buffers.log, make_log_event("second"))
      Scheduler.signal(pid)
      assert_receive {:envelope, envelope}, 500
      assert [%Sentry.LogBatch{log_events: [%LogEvent{body: "second"}]}] = envelope.items

      GenServer.stop(pid)
      stop_buffers(buffers)
    end
  end

  describe "transport queue capacity" do
    test "stops processing when transport queue is full" do
      buffers = start_test_buffers(batch_size: 1)
      uid = System.unique_integer([:positive])

      put_test_config(dsn: "http://public:secret@localhost:9999/1")

      {:ok, pid} =
        Scheduler.start_link(
          buffers: buffers,
          capacity: 0,
          name: :"test_scheduler_full_#{uid}"
        )

      # Add item and signal — should not process since capacity is 0
      Buffer.add(buffers.log, make_log_event("overflow"))
      Scheduler.signal(pid)

      # Give scheduler time to process
      Process.sleep(50)

      # Item should still be in buffer since transport queue has no space
      assert Buffer.size(buffers.log) == 1

      GenServer.stop(pid)
      stop_buffers(buffers)
    end

    test "items stay in buffer when transport queue is full" do
      buffers = start_test_buffers(batch_size: 1)
      uid = System.unique_integer([:positive])

      put_test_config(dsn: "http://public:secret@localhost:9999/1")

      {:ok, pid} =
        Scheduler.start_link(
          buffers: buffers,
          capacity: 1,
          name: :"test_scheduler_backpressure_#{uid}"
        )

      # Simulate full queue by setting size >= capacity
      :sys.replace_state(pid, fn state ->
        %{state | size: 1}
      end)

      Buffer.add(buffers.log, make_log_event("queued"))
      Scheduler.signal(pid)
      Process.sleep(50)

      # Item should remain in buffer since transport queue has no space
      assert Buffer.size(buffers.log) == 1

      GenServer.stop(pid)
      stop_buffers(buffers)
    end

    test "rejects envelope when its items would exceed capacity" do
      buffers = start_test_buffers(batch_size: 5)
      uid = System.unique_integer([:positive])

      put_test_config(dsn: "http://public:secret@localhost:9999/1")

      {:ok, pid} =
        Scheduler.start_link(
          buffers: buffers,
          capacity: 3,
          name: :"test_scheduler_item_count_#{uid}"
        )

      for i <- 1..5, do: Buffer.add(buffers.log, make_log_event("log_#{i}"))

      log =
        capture_log(fn ->
          Scheduler.signal(pid)
          Process.sleep(50)
        end)

      assert log =~ "transport queue full, dropping 5 item(s)"

      state = :sys.get_state(pid)
      assert state.size == 0

      GenServer.stop(pid)
      stop_buffers(buffers)
    end
  end

  describe "transport send process error handling" do
    test "logs warning when send process exits abnormally" do
      buffers = start_test_buffers(batch_size: 1)
      uid = System.unique_integer([:positive])

      {:ok, pid} =
        Scheduler.start_link(
          buffers: buffers,
          name: :"test_scheduler_down_#{uid}"
        )

      # Inject a fake active_ref into state, then send a matching :DOWN
      # with a crash reason to trigger the warning log.
      fake_ref = make_ref()

      :sys.replace_state(pid, fn state ->
        %{state | active_ref: fake_ref, active_item_count: 1, size: 1}
      end)

      log =
        capture_log(fn ->
          send(pid, {:DOWN, fake_ref, :process, self(), {:error, :something_broke}})
          # Synchronize: :sys.get_state goes through the mailbox, ensuring :DOWN is processed
          :sys.get_state(pid)
        end)

      assert log =~ "Sentry transport send process exited abnormally"
      assert log =~ "something_broke"

      GenServer.stop(pid)
      stop_buffers(buffers)
    end

    test "does not log on normal send process exit" do
      buffers = start_test_buffers(batch_size: 1)
      uid = System.unique_integer([:positive])

      {:ok, pid} =
        Scheduler.start_link(
          buffers: buffers,
          name: :"test_scheduler_normal_down_#{uid}"
        )

      fake_ref = make_ref()

      :sys.replace_state(pid, fn state ->
        %{state | active_ref: fake_ref, active_item_count: 1, size: 1}
      end)

      log =
        capture_log(fn ->
          send(pid, {:DOWN, fake_ref, :process, self(), :normal})
          :sys.get_state(pid)
        end)

      refute log =~ "Sentry transport send process exited abnormally"

      GenServer.stop(pid)
      stop_buffers(buffers)
    end
  end

  describe "transport send failure logging" do
    test "logs warning when direct transport send fails during flush" do
      bypass = Bypass.open()

      put_test_config(dsn: "http://public:secret@localhost:#{bypass.port}/1")
      prev_retries = Application.get_env(:sentry, :request_retries)
      Application.put_env(:sentry, :request_retries, [])

      on_exit(fn ->
        if prev_retries do
          Application.put_env(:sentry, :request_retries, prev_retries)
        else
          Application.delete_env(:sentry, :request_retries)
        end
      end)

      Bypass.expect(bypass, fn conn ->
        Plug.Conn.resp(conn, 500, ~s<{"error": "internal"}>)
      end)

      buffers = start_test_buffers(batch_size: 1)
      uid = System.unique_integer([:positive])

      {:ok, pid} =
        Scheduler.start_link(
          buffers: buffers,
          name: :"test_scheduler_send_fail_#{uid}"
        )

      Buffer.add(buffers.log, make_log_event("fail-send"))

      # Flush uses the direct send path which logs failures
      log =
        capture_log(fn ->
          Scheduler.flush(pid)
        end)

      assert log =~ "failed to send envelope"

      GenServer.stop(pid)
      stop_buffers(buffers)
      Bypass.down(bypass)
    end
  end

  # Helper functions

  defp start_test_buffers(opts \\ []) do
    uid = System.unique_integer([:positive])
    batch_size = Keyword.get(opts, :batch_size, 100)

    log_buf =
      start_supervised!(
        {Buffer, category: :log, batch_size: batch_size, name: :"test_log_buf_#{uid}"},
        id: :"test_log_buf_#{uid}"
      )

    %{log: log_buf}
  end

  defp stop_buffers(buffers) do
    for {_category, pid} <- buffers, Process.alive?(pid) do
      GenServer.stop(pid)
    end
  end

  defp receive_envelopes_until_empty(acc \\ []) do
    receive do
      {:envelope, envelope} ->
        receive_envelopes_until_empty([envelope | acc])
    after
      100 -> Enum.reverse(acc)
    end
  end
end
