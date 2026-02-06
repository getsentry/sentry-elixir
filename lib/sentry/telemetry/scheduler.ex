defmodule Sentry.Telemetry.Scheduler do
  @moduledoc """
  GenServer implementing a weighted round-robin scheduler for telemetry buffers.

  The scheduler cycles through category buffers based on priority weights,
  ensuring critical telemetry gets priority over high-volume data under load.

  Currently, only the `:log` category is managed. The weighted round-robin
  structure is in place for future expansion to additional categories.

  ## Weights

    * `:low` - weight 2 (logs)

  ## Signal-Based Wake

  The scheduler sleeps until signaled via `signal/1`. When signaled, it wakes
  and attempts to process items from the current buffer in the cycle. If the
  buffer is not ready or the transport queue is full, it advances to the next position.

  ## Transport Queue

  The scheduler includes a bounded FIFO queue for transport concurrency control,
  processing one envelope at a time (single-worker model). The queue is capped
  at a configurable capacity (default 1000 items) to prevent unbounded memory growth.
  For log envelopes, each log event counts as one item toward capacity.

  """
  @moduledoc since: "12.0.0"

  use GenServer

  require Logger

  alias __MODULE__

  alias Sentry.Telemetry.{Buffer, Category}
  alias Sentry.{ClientReport, Config, Envelope, LogEvent, Transport}

  @default_capacity 1000

  @type buffers :: %{
          log: GenServer.server()
        }

  defstruct [
    :buffers,
    :priority_cycle,
    :cycle_position,
    :on_envelope,
    :capacity,
    :active_ref,
    :active_item_count,
    queue: :queue.new(),
    size: 0
  ]

  @type t :: %Scheduler{
          buffers: buffers(),
          priority_cycle: [Category.t()],
          cycle_position: non_neg_integer(),
          on_envelope: (Envelope.t() -> any()) | nil,
          capacity: pos_integer(),
          queue: :queue.queue(),
          size: non_neg_integer(),
          active_ref: reference() | nil,
          active_item_count: non_neg_integer()
        }

  ## Public API

  @doc """
  Builds a priority cycle based on category weights.

  Returns a list of categories where each category appears a number of times
  equal to its priority weight.

  ## Examples

      iex> Sentry.Telemetry.Scheduler.build_priority_cycle()
      [:log, :log]

  """
  @spec build_priority_cycle(map() | nil) :: [Category.t()]
  def build_priority_cycle(weights \\ nil)
  def build_priority_cycle(nil), do: build_priority_cycle(default_weights())

  def build_priority_cycle(weights) when weights == %{},
    do: build_priority_cycle(default_weights())

  def build_priority_cycle(weights) when is_map(weights) do
    merged_weights = Map.merge(default_weights(), weights)

    for {category, priority} <- category_priority_mapping(),
        _i <- 1..Map.fetch!(merged_weights, priority) do
      category
    end
  end

  @doc """
  Starts the scheduler process.

  ## Options

    * `:buffers` - Map of category to buffer pid (required)
    * `:name` - The name to register the GenServer under (optional)
    * `:weights` - Custom priority weights (optional)
    * `:on_envelope` - Callback function invoked with built envelopes (optional)
    * `:capacity` - Maximum items in the transport queue (default: #{@default_capacity})

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
  Signals the scheduler to wake and process items.

  This is a non-blocking call that triggers the scheduler to check buffers
  and send any ready items.
  """
  @spec signal(GenServer.server()) :: :ok
  def signal(server) do
    GenServer.cast(server, :signal)
  end

  @doc """
  Flushes all buffers by draining their contents and sending all items.

  This is a blocking call that returns when all items have been processed,
  including any envelopes queued for transport.
  """
  @spec flush(GenServer.server(), timeout()) :: :ok
  def flush(server, timeout \\ 5000) do
    GenServer.call(server, :flush, timeout)
  end

  ## GenServer Callbacks

  @impl true
  def init(opts) do
    buffers = Keyword.fetch!(opts, :buffers)
    weights = Keyword.get(opts, :weights)
    on_envelope = Keyword.get(opts, :on_envelope)
    capacity = Keyword.get(opts, :capacity, @default_capacity)

    priority_cycle = build_priority_cycle(weights)

    state = %Scheduler{
      buffers: buffers,
      priority_cycle: priority_cycle,
      cycle_position: 0,
      on_envelope: on_envelope,
      capacity: capacity
    }

    {:ok, state}
  end

  @impl true
  def handle_cast(:signal, %Scheduler{} = state) do
    state = process_cycle(state)
    {:noreply, state}
  end

  @impl true
  def handle_call(:flush, _from, %Scheduler{} = state) do
    state = flush_all_buffers(state)
    state = wait_for_active(state)
    state = flush_queue(state)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{active_ref: ref} = state) do
    if reason != :normal do
      Logger.warning("Sentry transport send process exited abnormally: #{inspect(reason)}")
    end

    state = %{
      state
      | active_ref: nil,
        size: state.size - state.active_item_count,
        active_item_count: 0
    }

    state = maybe_process_next(state)

    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    {:noreply, state}
  end

  defp process_cycle(%Scheduler{} = state) do
    cycle_length = length(state.priority_cycle)
    max_attempts = cycle_length

    process_cycle(state, 0, max_attempts)
  end

  defp process_cycle(state, attempts, max_attempts) when attempts >= max_attempts do
    state
  end

  defp process_cycle(%Scheduler{} = state, attempts, max_attempts) do
    if not transport_has_space?(state) do
      # Transport queue is full, stop processing. Items stay in buffers.
      state
    else
      category = Enum.at(state.priority_cycle, state.cycle_position)
      buffer = Map.fetch!(state.buffers, category)

      case Buffer.poll_if_ready(buffer) do
        {:ok, items} when items != [] ->
          state = send_items(state, category, items)
          state = advance_cycle(state)
          process_cycle(state, attempts + 1, max_attempts)

        _ ->
          state = advance_cycle(state)
          process_cycle(state, attempts + 1, max_attempts)
      end
    end
  end

  defp send_items(state, :log, log_events) do
    process_and_send_logs(state, log_events, &send_envelope/2)
  end

  defp flush_all_buffers(%Scheduler{} = state) do
    for {category, buffer} <- state.buffers do
      items = Buffer.drain(buffer)

      if items != [] do
        case category do
          :log -> process_and_send_logs(state, items, &send_envelope_direct/2)
        end
      end
    end

    state
  end

  defp process_and_send_logs(%{on_envelope: on_envelope} = state, log_events, send_fn) do
    processed_logs = apply_before_send_log_callbacks(log_events)

    if processed_logs != [] do
      # Skip test collection when on_envelope is set (used by unit tests)
      if is_nil(on_envelope) do
        case Sentry.Test.maybe_collect_logs(processed_logs) do
          :collected ->
            state

          :not_collecting ->
            envelope = Envelope.from_log_events(processed_logs)
            send_fn.(state, envelope)
        end
      else
        envelope = Envelope.from_log_events(processed_logs)
        send_fn.(state, envelope)
      end
    else
      state
    end
  end

  defp apply_before_send_log_callbacks(log_events) do
    callback = Config.before_send_log()

    if callback do
      for log_event <- log_events,
          %LogEvent{} = modified_event <- [call_before_send_log(log_event, callback)] do
        modified_event
      end
    else
      log_events
    end
  end

  defp call_before_send_log(log_event, function) when is_function(function, 1) do
    function.(log_event)
  rescue
    error ->
      Logger.warning("before_send_log callback failed: #{inspect(error)}")

      log_event
  end

  defp call_before_send_log(log_event, {mod, fun}) do
    apply(mod, fun, [log_event])
  rescue
    error ->
      Logger.warning("before_send_log callback failed: #{inspect(error)}")

      log_event
  end

  defp advance_cycle(%Scheduler{} = state) do
    cycle_length = length(state.priority_cycle)
    new_position = rem(state.cycle_position + 1, cycle_length)
    %{state | cycle_position: new_position}
  end

  # Used during normal processing - enqueues to internal transport queue
  defp send_envelope(%Scheduler{on_envelope: callback} = state, envelope)
       when is_function(callback, 1) do
    callback.(envelope)
    state
  end

  defp send_envelope(%Scheduler{on_envelope: nil} = state, envelope) do
    item_count = Envelope.item_count(envelope)

    if state.size + item_count > state.capacity do
      Logger.warning("Sentry: transport queue full, dropping #{item_count} log item(s)")

      ClientReport.Sender.record_discarded_events(:queue_overflow, envelope.items)
      state
    else
      queue = :queue.in({envelope, item_count}, state.queue)
      state = %{state | queue: queue, size: state.size + item_count}
      maybe_process_next(state)
    end
  end

  # Used during flush - bypasses transport queue, sends directly or via callback
  defp send_envelope_direct(%Scheduler{on_envelope: callback}, envelope)
       when is_function(callback, 1) do
    callback.(envelope)
  end

  defp send_envelope_direct(%Scheduler{}, envelope) do
    send_direct(envelope)
  end

  defp send_direct(envelope) do
    client = Config.client()
    request_retries = Application.get_env(:sentry, :request_retries, Transport.default_retries())

    case Transport.encode_and_post_envelope(envelope, client, request_retries) do
      {:ok, _id} ->
        :ok

      {:error, error} ->
        Logger.warning("Sentry: failed to send log envelope: #{Exception.message(error)}")

        {:error, error}
    end
  end

  defp transport_has_space?(%{on_envelope: cb}) when is_function(cb, 1), do: true
  defp transport_has_space?(%{size: size, capacity: capacity}), do: size < capacity

  # Transport queue management (merged from QueueWorker)

  defp maybe_process_next(%{active_ref: ref} = state) when not is_nil(ref), do: state

  defp maybe_process_next(%Scheduler{} = state) do
    case :queue.out(state.queue) do
      {{:value, {envelope, item_count}}, queue} ->
        {_pid, ref} = spawn_monitor(fn -> send(envelope) end)
        %{state | queue: queue, active_ref: ref, active_item_count: item_count}

      {:empty, _queue} ->
        state
    end
  end

  defp send(envelope) do
    client = Config.client()
    request_retries = Application.get_env(:sentry, :request_retries, Transport.default_retries())
    Transport.encode_and_post_envelope(envelope, client, request_retries)
  end

  defp wait_for_active(%{active_ref: nil} = state), do: state

  defp wait_for_active(%{active_ref: ref} = state) do
    receive do
      {:DOWN, ^ref, :process, _pid, _reason} ->
        %{
          state
          | active_ref: nil,
            size: state.size - state.active_item_count,
            active_item_count: 0
        }
    after
      5000 ->
        Process.demonitor(ref, [:flush])

        %{
          state
          | active_ref: nil,
            size: state.size - state.active_item_count,
            active_item_count: 0
        }
    end
  end

  defp flush_queue(%Scheduler{} = state) do
    {entries, queue} = drain_queue(state.queue)
    Enum.each(entries, fn {envelope, _item_count} -> send(envelope) end)
    %{state | queue: queue, size: 0}
  end

  defp drain_queue(queue), do: drain_queue(queue, [])

  defp drain_queue(queue, acc) do
    case :queue.out(queue) do
      {{:value, entry}, queue} -> drain_queue(queue, [entry | acc])
      {:empty, queue} -> {Enum.reverse(acc), queue}
    end
  end

  defp default_weights do
    %{
      low: Category.weight(:low)
    }
  end

  defp category_priority_mapping do
    [
      {:log, :low}
    ]
  end
end
