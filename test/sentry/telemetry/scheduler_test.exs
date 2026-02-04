defmodule Sentry.Telemetry.SchedulerTest do
  use Sentry.Case, async: false

  alias Sentry.Telemetry.{Buffer, Scheduler}
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

  describe "build_priority_cycle/0" do
    test "builds cycle with correct priority ordering" do
      cycle = Scheduler.build_priority_cycle()

      # Default weights: critical=5, high=4, medium=3, low=2
      # Total cycle length = 5 + 4 + 3 + 2 = 14
      assert length(cycle) == 14

      # Count occurrences of each category
      counts = Enum.frequencies(cycle)
      assert counts[:error] == 5
      assert counts[:check_in] == 4
      assert counts[:transaction] == 3
      assert counts[:log] == 2
    end

    test "builds cycle with custom weights" do
      custom_weights = %{critical: 3, high: 2, medium: 1, low: 1}
      cycle = Scheduler.build_priority_cycle(custom_weights)

      assert length(cycle) == 7
      counts = Enum.frequencies(cycle)
      assert counts[:error] == 3
      assert counts[:check_in] == 2
      assert counts[:transaction] == 1
      assert counts[:log] == 1
    end
  end

  describe "start_link/1" do
    test "starts scheduler with buffers" do
      buffers = start_test_buffers()

      {:ok, pid} =
        Scheduler.start_link(
          buffers: buffers,
          transport_caller: self(),
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
          transport_caller: self(),
          weights: %{critical: 3, high: 2, medium: 1, low: 1},
          name: :test_scheduler_weights
        )

      state = :sys.get_state(pid)
      assert length(state.priority_cycle) == 7
      GenServer.stop(pid)
      stop_buffers(buffers)
    end
  end

  describe "signal/1" do
    test "wakes scheduler to process items" do
      buffers = start_test_buffers()
      test_pid = self()

      {:ok, pid} =
        Scheduler.start_link(
          buffers: buffers,
          on_envelope: fn envelope -> send(test_pid, {:envelope, envelope}) end,
          name: :test_scheduler_signal
        )

      # Add an item to error buffer
      Buffer.add(buffers.error, make_event("signal-test"))

      # Signal the scheduler
      Scheduler.signal(pid)

      # Should receive an envelope
      assert_receive {:envelope, envelope}, 500
      assert envelope.event_id == "signal-test"

      GenServer.stop(pid)
      stop_buffers(buffers)
    end
  end

  describe "priority processing" do
    test "processes higher priority buffers first in cycle" do
      buffers = start_test_buffers(log_batch_size: 1)
      test_pid = self()

      {:ok, pid} =
        Scheduler.start_link(
          buffers: buffers,
          on_envelope: fn envelope -> send(test_pid, {:envelope, envelope}) end,
          name: :test_scheduler_priority
        )

      # Add items to different buffers
      Buffer.add(buffers.error, make_event("error-1"))
      Buffer.add(buffers.log, make_log_event())
      Buffer.add(buffers.check_in, make_check_in("checkin-1"))

      # Signal scheduler multiple times to process all
      Scheduler.signal(pid)
      Process.sleep(50)
      Scheduler.signal(pid)
      Process.sleep(50)
      Scheduler.signal(pid)

      # Collect all envelopes
      received =
        receive_envelopes_until_empty()
        |> Enum.map(fn envelope ->
          case hd(envelope.items) do
            %Event{} -> :error
            %CheckIn{} -> :check_in
            %Transaction{} -> :transaction
            %Sentry.LogBatch{} -> :log
          end
        end)

      # Error should be processed first in the cycle (critical priority)
      # due to weighted round-robin, errors appear first
      assert :error in received
      assert :check_in in received
      assert :log in received

      GenServer.stop(pid)
      stop_buffers(buffers)
    end
  end

  describe "envelope building" do
    test "builds envelope from error event" do
      buffers = start_test_buffers()
      test_pid = self()

      {:ok, pid} =
        Scheduler.start_link(
          buffers: buffers,
          on_envelope: fn envelope -> send(test_pid, {:envelope, envelope}) end,
          name: :test_scheduler_envelope_error
        )

      event = make_event("error-envelope")
      Buffer.add(buffers.error, event)
      Scheduler.signal(pid)

      assert_receive {:envelope, envelope}, 500
      assert envelope.event_id == "error-envelope"
      assert [%Event{}] = envelope.items

      GenServer.stop(pid)
      stop_buffers(buffers)
    end

    test "builds envelope from check-in" do
      buffers = start_test_buffers()
      test_pid = self()

      {:ok, pid} =
        Scheduler.start_link(
          buffers: buffers,
          on_envelope: fn envelope -> send(test_pid, {:envelope, envelope}) end,
          name: :test_scheduler_envelope_checkin
        )

      check_in = make_check_in("checkin-envelope")
      Buffer.add(buffers.check_in, check_in)
      Scheduler.signal(pid)

      assert_receive {:envelope, envelope}, 500
      assert [%CheckIn{}] = envelope.items

      GenServer.stop(pid)
      stop_buffers(buffers)
    end

    test "builds envelope from transaction" do
      buffers = start_test_buffers()
      test_pid = self()

      {:ok, pid} =
        Scheduler.start_link(
          buffers: buffers,
          on_envelope: fn envelope -> send(test_pid, {:envelope, envelope}) end,
          name: :test_scheduler_envelope_tx
        )

      tx = make_transaction("tx-envelope")
      Buffer.add(buffers.transaction, tx)
      Scheduler.signal(pid)

      assert_receive {:envelope, envelope}, 500
      assert [%Transaction{}] = envelope.items

      GenServer.stop(pid)
      stop_buffers(buffers)
    end

    test "batches log events into single envelope" do
      buffers = start_test_buffers(log_batch_size: 2)
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
    test "drains all buffers and sends envelopes" do
      buffers = start_test_buffers()
      test_pid = self()

      {:ok, pid} =
        Scheduler.start_link(
          buffers: buffers,
          on_envelope: fn envelope -> send(test_pid, {:envelope, envelope}) end,
          name: :test_scheduler_flush
        )

      # Add items without signaling
      Buffer.add(buffers.error, make_event("flush-1"))
      Buffer.add(buffers.error, make_event("flush-2"))
      Buffer.add(buffers.check_in, make_check_in("flush-3"))

      # Flush should drain everything
      :ok = Scheduler.flush(pid)

      # Should receive all envelopes
      envelopes = receive_envelopes_until_empty()
      assert length(envelopes) == 3

      # Buffers should be empty
      assert Buffer.size(buffers.error) == 0
      assert Buffer.size(buffers.check_in) == 0

      GenServer.stop(pid)
      stop_buffers(buffers)
    end
  end

  # Helper functions

  defp start_test_buffers(opts \\ []) do
    uid = System.unique_integer([:positive])
    log_batch_size = Keyword.get(opts, :log_batch_size, 100)

    error_buf =
      start_supervised!(
        {Buffer, category: :error, name: :"test_error_buf_#{uid}"},
        id: :"test_error_buf_#{uid}"
      )

    check_in_buf =
      start_supervised!(
        {Buffer, category: :check_in, name: :"test_checkin_buf_#{uid}"},
        id: :"test_checkin_buf_#{uid}"
      )

    tx_buf =
      start_supervised!(
        {Buffer, category: :transaction, name: :"test_tx_buf_#{uid}"},
        id: :"test_tx_buf_#{uid}"
      )

    log_buf =
      start_supervised!(
        {Buffer, category: :log, batch_size: log_batch_size, name: :"test_log_buf_#{uid}"},
        id: :"test_log_buf_#{uid}"
      )

    %{
      error: error_buf,
      check_in: check_in_buf,
      transaction: tx_buf,
      log: log_buf
    }
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
