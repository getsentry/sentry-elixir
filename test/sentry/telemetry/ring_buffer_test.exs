defmodule Sentry.Telemetry.RingBufferTest do
  use ExUnit.Case, async: true

  alias Sentry.Telemetry.RingBuffer

  describe "new/1" do
    test "creates a buffer with specified capacity" do
      buffer = RingBuffer.new(capacity: 10)
      assert RingBuffer.capacity(buffer) == 10
    end

    test "creates a buffer with batch_size" do
      buffer = RingBuffer.new(capacity: 10, batch_size: 5)
      assert buffer.batch_size == 5
    end

    test "creates a buffer with timeout" do
      buffer = RingBuffer.new(capacity: 10, timeout: 5000)
      assert buffer.timeout == 5000
    end

    test "defaults batch_size to 1" do
      buffer = RingBuffer.new(capacity: 10)
      assert buffer.batch_size == 1
    end

    test "defaults timeout to nil" do
      buffer = RingBuffer.new(capacity: 10)
      assert buffer.timeout == nil
    end

    test "initializes last_flush_time" do
      buffer = RingBuffer.new(capacity: 10)
      assert is_integer(buffer.last_flush_time)
    end
  end

  describe "offer/2" do
    test "adds item to empty buffer" do
      buffer = RingBuffer.new(capacity: 3)
      {:ok, buffer} = RingBuffer.offer(buffer, :a)
      assert RingBuffer.size(buffer) == 1
    end

    test "adds multiple items" do
      buffer = RingBuffer.new(capacity: 3)
      {:ok, buffer} = RingBuffer.offer(buffer, :a)
      {:ok, buffer} = RingBuffer.offer(buffer, :b)
      {:ok, buffer} = RingBuffer.offer(buffer, :c)
      assert RingBuffer.size(buffer) == 3
    end

    test "drops oldest when full (overflow policy)" do
      buffer = RingBuffer.new(capacity: 2)
      {:ok, buffer} = RingBuffer.offer(buffer, :a)
      {:ok, buffer} = RingBuffer.offer(buffer, :b)
      {:dropped, buffer, :a} = RingBuffer.offer(buffer, :c)
      assert RingBuffer.size(buffer) == 2
      {items, _buffer} = RingBuffer.drain(buffer)
      assert items == [:b, :c]
    end
  end

  describe "poll/1" do
    test "returns nil for empty buffer" do
      buffer = RingBuffer.new(capacity: 3)
      assert {nil, ^buffer} = RingBuffer.poll(buffer)
    end

    test "returns oldest item (FIFO order)" do
      buffer = RingBuffer.new(capacity: 3)
      {:ok, buffer} = RingBuffer.offer(buffer, :a)
      {:ok, buffer} = RingBuffer.offer(buffer, :b)
      {:a, buffer} = RingBuffer.poll(buffer)
      assert RingBuffer.size(buffer) == 1
      {:b, buffer} = RingBuffer.poll(buffer)
      assert RingBuffer.size(buffer) == 0
    end
  end

  describe "poll_batch/2" do
    test "returns empty list for empty buffer" do
      buffer = RingBuffer.new(capacity: 5)
      {items, ^buffer} = RingBuffer.poll_batch(buffer, 3)
      assert items == []
    end

    test "returns up to batch_size items" do
      buffer = RingBuffer.new(capacity: 5)
      {:ok, buffer} = RingBuffer.offer(buffer, :a)
      {:ok, buffer} = RingBuffer.offer(buffer, :b)
      {:ok, buffer} = RingBuffer.offer(buffer, :c)
      {:ok, buffer} = RingBuffer.offer(buffer, :d)

      {items, buffer} = RingBuffer.poll_batch(buffer, 2)
      assert items == [:a, :b]
      assert RingBuffer.size(buffer) == 2
    end

    test "returns all items if less than batch_size available" do
      buffer = RingBuffer.new(capacity: 5)
      {:ok, buffer} = RingBuffer.offer(buffer, :a)
      {:ok, buffer} = RingBuffer.offer(buffer, :b)

      {items, buffer} = RingBuffer.poll_batch(buffer, 5)
      assert items == [:a, :b]
      assert RingBuffer.size(buffer) == 0
    end
  end

  describe "poll_if_ready/1" do
    test "returns batch when size >= batch_size" do
      buffer = RingBuffer.new(capacity: 10, batch_size: 2)
      {:ok, buffer} = RingBuffer.offer(buffer, :a)
      {:ok, buffer} = RingBuffer.offer(buffer, :b)
      {:ok, buffer} = RingBuffer.offer(buffer, :c)

      {:ok, items, buffer} = RingBuffer.poll_if_ready(buffer)
      assert items == [:a, :b]
      assert RingBuffer.size(buffer) == 1
    end

    test "returns :not_ready when size < batch_size and no timeout" do
      buffer = RingBuffer.new(capacity: 10, batch_size: 3)
      {:ok, buffer} = RingBuffer.offer(buffer, :a)

      assert {:not_ready, ^buffer} = RingBuffer.poll_if_ready(buffer)
    end

    test "returns batch when timeout elapsed even if size < batch_size" do
      # Create buffer with 1ms timeout and simulate time passage
      buffer = RingBuffer.new(capacity: 10, batch_size: 10, timeout: 1)
      {:ok, buffer} = RingBuffer.offer(buffer, :a)
      # Simulate old last_flush_time
      buffer = %{buffer | last_flush_time: System.monotonic_time(:millisecond) - 100}

      {:ok, items, _buffer} = RingBuffer.poll_if_ready(buffer)
      assert items == [:a]
    end

    test "returns :not_ready when empty even if timeout elapsed" do
      buffer = RingBuffer.new(capacity: 10, batch_size: 10, timeout: 1)
      buffer = %{buffer | last_flush_time: System.monotonic_time(:millisecond) - 100}

      assert {:not_ready, ^buffer} = RingBuffer.poll_if_ready(buffer)
    end
  end

  describe "drain/1" do
    test "returns all items and empties buffer" do
      buffer = RingBuffer.new(capacity: 5)
      {:ok, buffer} = RingBuffer.offer(buffer, :a)
      {:ok, buffer} = RingBuffer.offer(buffer, :b)
      {:ok, buffer} = RingBuffer.offer(buffer, :c)

      {items, buffer} = RingBuffer.drain(buffer)
      assert items == [:a, :b, :c]
      assert RingBuffer.size(buffer) == 0
    end

    test "returns empty list for empty buffer" do
      buffer = RingBuffer.new(capacity: 5)
      {items, ^buffer} = RingBuffer.drain(buffer)
      assert items == []
    end
  end

  describe "size/1" do
    test "returns 0 for empty buffer" do
      buffer = RingBuffer.new(capacity: 5)
      assert RingBuffer.size(buffer) == 0
    end

    test "returns correct count after operations" do
      buffer = RingBuffer.new(capacity: 5)
      {:ok, buffer} = RingBuffer.offer(buffer, :a)
      {:ok, buffer} = RingBuffer.offer(buffer, :b)
      assert RingBuffer.size(buffer) == 2

      {_item, buffer} = RingBuffer.poll(buffer)
      assert RingBuffer.size(buffer) == 1
    end
  end

  describe "capacity/1" do
    test "returns the configured capacity" do
      buffer = RingBuffer.new(capacity: 42)
      assert RingBuffer.capacity(buffer) == 42
    end
  end

  describe "is_full?/1" do
    test "returns false when buffer has space" do
      buffer = RingBuffer.new(capacity: 3)
      {:ok, buffer} = RingBuffer.offer(buffer, :a)
      refute RingBuffer.is_full?(buffer)
    end

    test "returns true when buffer is at capacity" do
      buffer = RingBuffer.new(capacity: 2)
      {:ok, buffer} = RingBuffer.offer(buffer, :a)
      {:ok, buffer} = RingBuffer.offer(buffer, :b)
      assert RingBuffer.is_full?(buffer)
    end
  end

  describe "is_ready_to_flush?/1" do
    test "returns true when size >= batch_size" do
      buffer = RingBuffer.new(capacity: 10, batch_size: 2)
      {:ok, buffer} = RingBuffer.offer(buffer, :a)
      {:ok, buffer} = RingBuffer.offer(buffer, :b)
      assert RingBuffer.is_ready_to_flush?(buffer)
    end

    test "returns false when size < batch_size and no timeout" do
      buffer = RingBuffer.new(capacity: 10, batch_size: 3)
      {:ok, buffer} = RingBuffer.offer(buffer, :a)
      refute RingBuffer.is_ready_to_flush?(buffer)
    end

    test "returns true when timeout elapsed and buffer not empty" do
      buffer = RingBuffer.new(capacity: 10, batch_size: 10, timeout: 1)
      {:ok, buffer} = RingBuffer.offer(buffer, :a)
      buffer = %{buffer | last_flush_time: System.monotonic_time(:millisecond) - 100}
      assert RingBuffer.is_ready_to_flush?(buffer)
    end

    test "returns false when empty even if timeout elapsed" do
      buffer = RingBuffer.new(capacity: 10, batch_size: 10, timeout: 1)
      buffer = %{buffer | last_flush_time: System.monotonic_time(:millisecond) - 100}
      refute RingBuffer.is_ready_to_flush?(buffer)
    end
  end

  describe "mark_flushed/1" do
    test "updates last_flush_time" do
      buffer = RingBuffer.new(capacity: 10)
      old_time = buffer.last_flush_time
      Process.sleep(1)
      buffer = RingBuffer.mark_flushed(buffer)
      assert buffer.last_flush_time > old_time
    end
  end

  describe "FIFO ordering across wrap-around" do
    test "maintains FIFO order when buffer wraps around" do
      buffer = RingBuffer.new(capacity: 3)

      # Fill buffer
      {:ok, buffer} = RingBuffer.offer(buffer, 1)
      {:ok, buffer} = RingBuffer.offer(buffer, 2)
      {:ok, buffer} = RingBuffer.offer(buffer, 3)

      # Poll one
      {1, buffer} = RingBuffer.poll(buffer)

      # Add another (wraps around)
      {:ok, buffer} = RingBuffer.offer(buffer, 4)

      # Drain should be in FIFO order
      {items, _buffer} = RingBuffer.drain(buffer)
      assert items == [2, 3, 4]
    end
  end
end
