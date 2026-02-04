defmodule Sentry.Telemetry.RingBuffer do
  @moduledoc """
  A generic ring buffer (circular buffer) for storing telemetry items.

  This module implements a fixed-capacity FIFO buffer with configurable batch size
  and timeout for flush readiness. When the buffer is full, new items cause the
  oldest items to be dropped (overflow policy: drop oldest).

  ## Options

    * `:capacity` - Maximum number of items (required)
    * `:batch_size` - Number of items per batch for flushing (default: 1)
    * `:timeout` - Flush timeout in milliseconds (default: nil, no timeout-based flush)

  ## Example

      buffer = RingBuffer.new(capacity: 100, batch_size: 10, timeout: 5000)
      {:ok, buffer} = RingBuffer.offer(buffer, item)
      {items, buffer} = RingBuffer.poll_batch(buffer, 10)

  """
  @moduledoc since: "11.0.0"

  @enforce_keys [:capacity, :batch_size]
  defstruct [
    :capacity,
    :batch_size,
    :timeout,
    :last_flush_time,
    items: :queue.new(),
    size: 0
  ]

  @opaque t :: %__MODULE__{
            capacity: pos_integer(),
            batch_size: pos_integer(),
            timeout: pos_integer() | nil,
            last_flush_time: integer(),
            items: :queue.queue(),
            size: non_neg_integer()
          }

  @doc """
  Creates a new ring buffer with the given options.

  ## Options

    * `:capacity` - Maximum number of items (required)
    * `:batch_size` - Items per batch (default: 1)
    * `:timeout` - Flush timeout in ms (default: nil)

  """
  @dialyzer {:no_opaque, new: 1}
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts) do
    capacity = Keyword.fetch!(opts, :capacity)
    batch_size = Keyword.get(opts, :batch_size, 1)
    timeout = Keyword.get(opts, :timeout, nil)

    %__MODULE__{
      capacity: capacity,
      batch_size: batch_size,
      timeout: timeout,
      last_flush_time: System.monotonic_time(:millisecond)
    }
  end

  @doc """
  Adds an item to the buffer.

  Returns `{:ok, buffer}` if added normally, or `{:dropped, buffer, dropped_item}`
  if the buffer was full and the oldest item was dropped.
  """
  @spec offer(t(), term()) :: {:ok, t()} | {:dropped, t(), term()}
  def offer(%__MODULE__{} = buffer, item) do
    if buffer.size >= buffer.capacity do
      # Drop oldest (head of queue)
      {{:value, dropped}, new_items} = :queue.out(buffer.items)
      new_items = :queue.in(item, new_items)
      {:dropped, %{buffer | items: new_items}, dropped}
    else
      new_items = :queue.in(item, buffer.items)
      {:ok, %{buffer | items: new_items, size: buffer.size + 1}}
    end
  end

  @doc """
  Removes and returns the oldest item from the buffer.

  Returns `{item, buffer}` or `{nil, buffer}` if empty.
  """
  @spec poll(t()) :: {term() | nil, t()}
  def poll(%__MODULE__{size: 0} = buffer), do: {nil, buffer}

  def poll(%__MODULE__{} = buffer) do
    {{:value, item}, new_items} = :queue.out(buffer.items)
    {item, %{buffer | items: new_items, size: buffer.size - 1}}
  end

  @doc """
  Removes and returns up to `count` items from the buffer.

  Returns `{items, buffer}` where items is a list in FIFO order.
  """
  @spec poll_batch(t(), pos_integer()) :: {[term()], t()}
  def poll_batch(%__MODULE__{} = buffer, count) when count > 0 do
    poll_batch(buffer, count, [])
  end

  defp poll_batch(buffer, 0, acc), do: {Enum.reverse(acc), buffer}
  defp poll_batch(%{size: 0} = buffer, _count, acc), do: {Enum.reverse(acc), buffer}

  defp poll_batch(buffer, count, acc) do
    {item, buffer} = poll(buffer)
    poll_batch(buffer, count - 1, [item | acc])
  end

  @doc """
  Polls a batch if the buffer is ready to flush.

  Returns `{:ok, items, buffer}` if ready, or `{:not_ready, buffer}` if not.
  The buffer is ready when:
    - Size >= batch_size, OR
    - Timeout has elapsed AND buffer is not empty
  """
  @spec poll_if_ready(t()) :: {:ok, [term()], t()} | {:not_ready, t()}
  def poll_if_ready(%__MODULE__{} = buffer) do
    if is_ready_to_flush?(buffer) do
      batch_count = min(buffer.batch_size, buffer.size)
      {items, buffer} = poll_batch(buffer, batch_count)
      buffer = mark_flushed(buffer)
      {:ok, items, buffer}
    else
      {:not_ready, buffer}
    end
  end

  @doc """
  Removes and returns all items from the buffer.

  Returns `{items, buffer}` where items is a list in FIFO order.
  """
  @spec drain(t()) :: {[term()], t()}
  def drain(%__MODULE__{} = buffer) do
    items = :queue.to_list(buffer.items)
    {items, %{buffer | items: :queue.new(), size: 0}}
  end

  @doc """
  Returns the number of items in the buffer.
  """
  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{size: size}), do: size

  @doc """
  Returns the capacity of the buffer.
  """
  @spec capacity(t()) :: pos_integer()
  def capacity(%__MODULE__{capacity: capacity}), do: capacity

  @doc """
  Returns true if the buffer is at capacity.
  """
  @spec is_full?(t()) :: boolean()
  def is_full?(%__MODULE__{} = buffer), do: buffer.size >= buffer.capacity

  @doc """
  Returns true if the buffer is ready to flush.

  Ready conditions:
    - Size >= batch_size, OR
    - Timeout has elapsed AND buffer is not empty
  """
  @spec is_ready_to_flush?(t()) :: boolean()
  def is_ready_to_flush?(%__MODULE__{size: 0}), do: false

  def is_ready_to_flush?(%__MODULE__{} = buffer) do
    buffer.size >= buffer.batch_size or timeout_elapsed?(buffer)
  end

  @doc """
  Updates the last_flush_time to the current time.
  """
  @spec mark_flushed(t()) :: t()
  def mark_flushed(%__MODULE__{} = buffer) do
    %{buffer | last_flush_time: System.monotonic_time(:millisecond)}
  end

  defp timeout_elapsed?(%{timeout: nil}), do: false

  defp timeout_elapsed?(%{timeout: timeout, last_flush_time: last_flush_time}) do
    now = System.monotonic_time(:millisecond)
    now - last_flush_time >= timeout
  end
end
