defmodule Sentry.Telemetry.Buffer do
  @moduledoc """
  GenServer wrapping a RingBuffer for a single telemetry category.

  This module provides a concurrent buffer for a specific category of telemetry
  items (errors, transactions, check-ins, or logs). It uses the `RingBuffer` data
  structure internally and provides a GenServer interface for safe concurrent access.

  ## Options

    * `:category` - The telemetry category (required). One of `:error`, `:check_in`,
      `:transaction`, or `:log`
    * `:name` - The name to register the GenServer under (optional)
    * `:capacity` - Buffer capacity (defaults to category default)
    * `:batch_size` - Items per batch (defaults to category default)
    * `:timeout` - Flush timeout in ms (defaults to category default)
    * `:on_item` - Optional callback function invoked when an item is added

  """
  @moduledoc since: "11.0.0"

  use GenServer

  alias Sentry.Telemetry.{Category, RingBuffer}

  @enforce_keys [:category]
  defstruct [:category, :capacity, :batch_size, :timeout, :ring_buffer, :on_item]

  @type t :: %__MODULE__{
          category: Category.t(),
          capacity: pos_integer(),
          batch_size: pos_integer(),
          timeout: pos_integer() | nil,
          ring_buffer: RingBuffer.t(),
          on_item: (-> any()) | nil
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

    capacity = Keyword.get(opts, :capacity, defaults.capacity)
    batch_size = Keyword.get(opts, :batch_size, defaults.batch_size)
    timeout = Keyword.get(opts, :timeout, defaults.timeout)
    on_item = Keyword.get(opts, :on_item)

    ring_buffer =
      RingBuffer.new(
        capacity: capacity,
        batch_size: batch_size,
        timeout: timeout
      )

    state = %__MODULE__{
      category: category,
      capacity: capacity,
      batch_size: batch_size,
      timeout: timeout,
      ring_buffer: ring_buffer,
      on_item: on_item
    }

    {:ok, state}
  end

  @impl true
  def handle_cast({:add, item}, %__MODULE__{} = state) do
    {_result, ring_buffer} =
      case RingBuffer.offer(state.ring_buffer, item) do
        {:ok, rb} -> {:ok, rb}
        {:dropped, rb, _dropped} -> {:dropped, rb}
      end

    state = %{state | ring_buffer: ring_buffer}

    # Invoke callback if provided
    if state.on_item, do: state.on_item.()

    {:noreply, state}
  end

  @impl true
  def handle_call(:poll_if_ready, _from, %__MODULE__{} = state) do
    case RingBuffer.poll_if_ready(state.ring_buffer) do
      {:ok, items, ring_buffer} ->
        {:reply, {:ok, items}, %{state | ring_buffer: ring_buffer}}

      {:not_ready, ring_buffer} ->
        {:reply, :not_ready, %{state | ring_buffer: ring_buffer}}
    end
  end

  def handle_call(:drain, _from, %__MODULE__{} = state) do
    {items, ring_buffer} = RingBuffer.drain(state.ring_buffer)
    {:reply, items, %{state | ring_buffer: ring_buffer}}
  end

  def handle_call(:size, _from, %__MODULE__{} = state) do
    {:reply, RingBuffer.size(state.ring_buffer), state}
  end

  def handle_call(:is_ready?, _from, %__MODULE__{} = state) do
    {:reply, RingBuffer.is_ready_to_flush?(state.ring_buffer), state}
  end

  def handle_call(:category, _from, %__MODULE__{} = state) do
    {:reply, state.category, state}
  end
end
