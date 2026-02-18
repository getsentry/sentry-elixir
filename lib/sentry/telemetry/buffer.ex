defmodule Sentry.Telemetry.Buffer do
  @moduledoc """
  A fixed-capacity FIFO buffer for telemetry items with batch-aware flushing.

  This module is both a GenServer and a struct. The struct holds the buffer state
  (a bounded queue with overflow-drops-oldest semantics), while the GenServer
  provides concurrent access for producers and consumers.

  ## Options

    * `:category` - The telemetry category (required), currently only `:log`
    * `:name` - The name to register the GenServer under (optional)
    * `:capacity` - Buffer capacity (defaults to category default)
    * `:batch_size` - Items per batch (defaults to category default)
    * `:timeout` - Flush timeout in ms (defaults to category default)
    * `:on_item` - Optional callback function invoked when an item is added

  """
  @moduledoc since: "12.0.0"

  use GenServer

  alias __MODULE__
  alias Sentry.Telemetry.Category

  @enforce_keys [:category, :capacity, :batch_size]
  defstruct [
    :category,
    :capacity,
    :batch_size,
    :timeout,
    :on_item,
    :last_flush_time,
    items: :queue.new(),
    size: 0
  ]

  @type t :: %Buffer{
          category: Category.t(),
          capacity: pos_integer(),
          batch_size: pos_integer(),
          timeout: pos_integer() | nil,
          on_item: (-> any()) | nil,
          last_flush_time: integer(),
          items: :queue.queue(),
          size: non_neg_integer()
        }

  ## Public API

  @doc """
  Starts the buffer process.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    {name, opts} = Keyword.pop(opts, :name)

    if name do
      GenServer.start_link(__MODULE__, opts, name: name)
    else
      GenServer.start_link(__MODULE__, opts)
    end
  end

  @doc """
  Adds an item to the buffer.

  Returns `:ok`. If the buffer is full, the oldest item is dropped.
  If an `on_item` callback was provided, it will be invoked.
  """
  @spec add(GenServer.server(), term()) :: :ok
  def add(server, item) do
    GenServer.cast(server, {:add, item})
  end

  @doc """
  Polls a batch of items if the buffer is ready to flush.

  Returns `{:ok, items}` if ready, or `:not_ready` if not.
  """
  @spec poll_if_ready(GenServer.server()) :: {:ok, [term()]} | :not_ready
  def poll_if_ready(server) do
    GenServer.call(server, :poll_if_ready)
  end

  @doc """
  Drains all items from the buffer.

  Returns a list of all items in FIFO order.
  """
  @spec drain(GenServer.server()) :: [term()]
  def drain(server) do
    GenServer.call(server, :drain)
  end

  @doc """
  Returns the current number of items in the buffer.
  """
  @spec size(GenServer.server()) :: non_neg_integer()
  def size(server) do
    GenServer.call(server, :size)
  end

  @doc """
  Returns whether the buffer is ready to flush.
  """
  @spec is_ready?(GenServer.server()) :: boolean()
  def is_ready?(server) do
    GenServer.call(server, :is_ready?)
  end

  @doc """
  Returns the buffer's category.
  """
  @spec category(GenServer.server()) :: Category.t()
  def category(server) do
    GenServer.call(server, :category)
  end

  ## GenServer Callbacks

  @impl true
  def init(opts) do
    category = Keyword.fetch!(opts, :category)
    defaults = Category.default_config(category)

    state = %Buffer{
      category: category,
      capacity: Keyword.get(opts, :capacity, defaults.capacity),
      batch_size: Keyword.get(opts, :batch_size, defaults.batch_size),
      timeout: Keyword.get(opts, :timeout, defaults.timeout),
      on_item: Keyword.get(opts, :on_item),
      last_flush_time: System.monotonic_time(:millisecond)
    }

    {:ok, state}
  end

  @impl true
  def handle_cast({:add, item}, %Buffer{} = state) do
    state = offer(state, item)

    if state.on_item, do: state.on_item.()

    {:noreply, state}
  end

  @impl true
  def handle_call(:poll_if_ready, _from, %Buffer{} = state) do
    if ready_to_flush?(state) do
      batch_count = min(state.batch_size, state.size)
      {items, state} = poll_batch(state, batch_count)
      state = %{state | last_flush_time: System.monotonic_time(:millisecond)}
      {:reply, {:ok, items}, state}
    else
      {:reply, :not_ready, state}
    end
  end

  def handle_call(:drain, _from, %Buffer{} = state) do
    items = :queue.to_list(state.items)
    {:reply, items, %{state | items: :queue.new(), size: 0}}
  end

  def handle_call(:size, _from, %Buffer{} = state) do
    {:reply, state.size, state}
  end

  def handle_call(:is_ready?, _from, %Buffer{} = state) do
    {:reply, ready_to_flush?(state), state}
  end

  def handle_call(:category, _from, %Buffer{} = state) do
    {:reply, state.category, state}
  end

  defp offer(%Buffer{size: size, capacity: capacity} = state, item)
       when size >= capacity do
    {{:value, _dropped}, items} = :queue.out(state.items)
    %{state | items: :queue.in(item, items)}
  end

  defp offer(%Buffer{} = state, item) do
    %{state | items: :queue.in(item, state.items), size: state.size + 1}
  end

  defp poll_batch(state, count), do: poll_batch(state, count, [])
  defp poll_batch(state, 0, acc), do: {Enum.reverse(acc), state}
  defp poll_batch(%{size: 0} = state, _count, acc), do: {Enum.reverse(acc), state}

  defp poll_batch(state, count, acc) do
    {{:value, item}, items} = :queue.out(state.items)
    state = %{state | items: items, size: state.size - 1}
    poll_batch(state, count - 1, [item | acc])
  end

  defp ready_to_flush?(%{size: 0}), do: false

  defp ready_to_flush?(%{size: size, batch_size: batch_size} = state) do
    size >= batch_size or timeout_elapsed?(state)
  end

  defp timeout_elapsed?(%{timeout: nil}), do: false

  defp timeout_elapsed?(%{timeout: timeout, last_flush_time: last_flush_time}) do
    System.monotonic_time(:millisecond) - last_flush_time >= timeout
  end
end
