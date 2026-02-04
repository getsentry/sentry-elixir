defmodule Sentry.Telemetry.BufferTest do
  use Sentry.Case, async: false

  alias Sentry.Telemetry.Buffer
  alias Sentry.Telemetry.Category

  defp make_event(id) do
    %Sentry.Event{event_id: id, timestamp: DateTime.utc_now()}
  end

  describe "start_link/1" do
    test "starts with required category option" do
      assert {:ok, pid} = Buffer.start_link(category: :error, name: :test_buffer_start)
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "uses default config from Category module" do
      assert {:ok, pid} = Buffer.start_link(category: :log, name: :test_buffer_defaults)
      state = :sys.get_state(pid)

      defaults = Category.default_config(:log)
      assert state.capacity == defaults.capacity
      assert state.batch_size == defaults.batch_size
      assert state.timeout == defaults.timeout
      GenServer.stop(pid)
    end

    test "allows overriding capacity, batch_size, and timeout" do
      assert {:ok, pid} =
               Buffer.start_link(
                 category: :error,
                 name: :test_buffer_override,
                 capacity: 50,
                 batch_size: 10,
                 timeout: 1000
               )

      state = :sys.get_state(pid)
      assert state.capacity == 50
      assert state.batch_size == 10
      assert state.timeout == 1000
      GenServer.stop(pid)
    end
  end

  describe "add/2" do
    test "adds item to buffer" do
      {:ok, pid} = Buffer.start_link(category: :error, name: :test_buffer_add)
      assert :ok = Buffer.add(pid, make_event("test1"))
      assert Buffer.size(pid) == 1
      GenServer.stop(pid)
    end

    test "signals on_item callback when provided" do
      test_pid = self()

      {:ok, pid} =
        Buffer.start_link(
          category: :error,
          name: :test_buffer_signal,
          on_item: fn -> send(test_pid, :item_added) end
        )

      Buffer.add(pid, make_event("test1"))
      assert_receive :item_added, 100
      GenServer.stop(pid)
    end
  end

  describe "poll_if_ready/1" do
    test "returns batch when ready (size >= batch_size)" do
      {:ok, pid} = Buffer.start_link(category: :error, name: :test_buffer_poll, batch_size: 2)
      Buffer.add(pid, make_event("e1"))
      Buffer.add(pid, make_event("e2"))

      {:ok, items} = Buffer.poll_if_ready(pid)
      assert length(items) == 2
      assert Buffer.size(pid) == 0
      GenServer.stop(pid)
    end

    test "returns :not_ready when size < batch_size and no timeout" do
      {:ok, pid} =
        Buffer.start_link(category: :error, name: :test_buffer_not_ready, batch_size: 5)

      Buffer.add(pid, make_event("e1"))

      assert :not_ready = Buffer.poll_if_ready(pid)
      GenServer.stop(pid)
    end
  end

  describe "drain/1" do
    test "returns all items and empties buffer" do
      {:ok, pid} = Buffer.start_link(category: :error, name: :test_buffer_drain)
      Buffer.add(pid, make_event("e1"))
      Buffer.add(pid, make_event("e2"))

      items = Buffer.drain(pid)
      assert length(items) == 2
      assert Buffer.size(pid) == 0
      GenServer.stop(pid)
    end
  end

  describe "size/1" do
    test "returns current buffer size" do
      {:ok, pid} = Buffer.start_link(category: :error, name: :test_buffer_size)
      assert Buffer.size(pid) == 0
      Buffer.add(pid, make_event("e1"))
      assert Buffer.size(pid) == 1
      GenServer.stop(pid)
    end
  end

  describe "is_ready?/1" do
    test "returns true when buffer is ready to flush" do
      {:ok, pid} = Buffer.start_link(category: :error, name: :test_buffer_ready, batch_size: 1)
      Buffer.add(pid, make_event("e1"))
      assert Buffer.is_ready?(pid) == true
      GenServer.stop(pid)
    end

    test "returns false when buffer is not ready" do
      {:ok, pid} =
        Buffer.start_link(category: :error, name: :test_buffer_not_ready2, batch_size: 10)

      Buffer.add(pid, make_event("e1"))
      assert Buffer.is_ready?(pid) == false
      GenServer.stop(pid)
    end
  end

  describe "overflow behavior" do
    test "drops oldest item when buffer is full" do
      {:ok, pid} = Buffer.start_link(category: :error, name: :test_buffer_overflow, capacity: 2)
      Buffer.add(pid, make_event("e1"))
      Buffer.add(pid, make_event("e2"))
      Buffer.add(pid, make_event("e3"))

      # Size should still be 2
      assert Buffer.size(pid) == 2

      # Drain should show e2 and e3 (e1 was dropped)
      items = Buffer.drain(pid)
      event_ids = Enum.map(items, & &1.event_id)
      assert event_ids == ["e2", "e3"]
      GenServer.stop(pid)
    end
  end

  describe "category/1" do
    test "returns the buffer's category" do
      {:ok, pid} = Buffer.start_link(category: :transaction, name: :test_buffer_category)
      assert Buffer.category(pid) == :transaction
      GenServer.stop(pid)
    end
  end
end
