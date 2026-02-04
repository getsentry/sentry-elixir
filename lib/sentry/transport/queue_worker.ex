defmodule Sentry.Transport.QueueWorker do
  @moduledoc false

  # Bounded FIFO queue for transport concurrency control.
  #
  # Sits between the Scheduler and HTTP transport, processing one envelope
  # at a time (single-worker model). The queue is capped at a configurable
  # capacity (default 1000) to prevent unbounded memory growth.

  use GenServer

  alias Sentry.{Config, Transport}

  @default_capacity 1000

  defstruct [:capacity, :queue, :size, :active_ref]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    {name, opts} = Keyword.pop(opts, :name)

    if name do
      GenServer.start_link(__MODULE__, opts, name: name)
    else
      GenServer.start_link(__MODULE__, opts)
    end
  end

  @spec enqueue(GenServer.server(), Sentry.Envelope.t()) :: :ok | :full
  def enqueue(server, envelope) do
    GenServer.call(server, {:enqueue, envelope})
  end

  @spec flush(GenServer.server(), timeout()) :: :ok
  def flush(server, timeout \\ 5000) do
    GenServer.call(server, :flush, timeout)
  end

  @spec has_space?(GenServer.server()) :: boolean()
  def has_space?(server) do
    GenServer.call(server, :has_space?)
  end

  @spec pending_count(GenServer.server()) :: non_neg_integer()
  def pending_count(server) do
    GenServer.call(server, :pending_count)
  end

  @impl true
  def init(opts) do
    capacity = Keyword.get(opts, :capacity, @default_capacity)

    state = %__MODULE__{
      capacity: capacity,
      queue: :queue.new(),
      size: 0,
      active_ref: nil
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:enqueue, envelope}, _from, %__MODULE__{} = state) do
    if state.size >= state.capacity do
      {:reply, :full, state}
    else
      queue = :queue.in(envelope, state.queue)
      state = %{state | queue: queue, size: state.size + 1}
      state = maybe_process_next(state)
      {:reply, :ok, state}
    end
  end

  def handle_call(:flush, _from, %__MODULE__{} = state) do
    state = wait_for_active(state)
    state = flush_queue(state)
    {:reply, :ok, state}
  end

  def handle_call(:has_space?, _from, %__MODULE__{} = state) do
    {:reply, state.size < state.capacity, state}
  end

  def handle_call(:pending_count, _from, %__MODULE__{} = state) do
    total = state.size + if(state.active_ref, do: 1, else: 0)
    {:reply, total, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{active_ref: ref} = state) do
    state = %{state | active_ref: nil}
    state = maybe_process_next(state)
    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    {:noreply, state}
  end

  defp maybe_process_next(%{active_ref: ref} = state) when not is_nil(ref), do: state

  defp maybe_process_next(%__MODULE__{} = state) do
    case :queue.out(state.queue) do
      {{:value, envelope}, queue} ->
        {_pid, ref} = spawn_monitor(fn -> do_send(envelope) end)
        %{state | queue: queue, size: state.size - 1, active_ref: ref}

      {:empty, _queue} ->
        state
    end
  end

  defp do_send(envelope) do
    client = Config.client()
    request_retries = Application.get_env(:sentry, :request_retries, Transport.default_retries())
    Transport.encode_and_post_envelope(envelope, client, request_retries)
  end

  defp wait_for_active(%{active_ref: nil} = state), do: state

  defp wait_for_active(%{active_ref: ref} = state) do
    receive do
      {:DOWN, ^ref, :process, _pid, _reason} ->
        %{state | active_ref: nil}
    after
      5000 ->
        Process.demonitor(ref, [:flush])
        %{state | active_ref: nil}
    end
  end

  defp flush_queue(%__MODULE__{} = state) do
    {items, queue} = drain_queue(state.queue)
    Enum.each(items, &do_send/1)
    %{state | queue: queue, size: 0}
  end

  defp drain_queue(queue), do: drain_queue(queue, [])

  defp drain_queue(queue, acc) do
    case :queue.out(queue) do
      {{:value, item}, queue} -> drain_queue(queue, [item | acc])
      {:empty, queue} -> {Enum.reverse(acc), queue}
    end
  end
end
