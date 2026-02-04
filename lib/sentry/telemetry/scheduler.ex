defmodule Sentry.Telemetry.Scheduler do
  @moduledoc """
  GenServer implementing a weighted round-robin scheduler for telemetry buffers.

  The scheduler cycles through category buffers based on priority weights,
  ensuring critical telemetry (errors) gets priority over high-volume data (logs)
  under load.

  ## Weights

  The scheduler builds a priority cycle based on weights per priority level:

    * `:critical` - weight 5 (errors)
    * `:high` - weight 4 (check-ins)
    * `:medium` - weight 3 (transactions)
    * `:low` - weight 2 (logs)

  The resulting cycle contains each category repeated according to its weight,
  ensuring higher-priority telemetry gets more send opportunities.

  ## Signal-Based Wake

  The scheduler sleeps until signaled via `signal/1`. When signaled, it wakes
  and attempts to process items from the current buffer in the cycle. If the
  buffer is not ready or is rate-limited, it advances to the next position.

  """
  @moduledoc since: "11.0.0"

  use GenServer

  alias Sentry.Telemetry.{Buffer, Category}
  alias Sentry.Transport.QueueWorker
  alias Sentry.{Config, Envelope, Event, CheckIn, LogEvent, Transaction, Transport}

  @type buffers :: %{
          error: GenServer.server(),
          check_in: GenServer.server(),
          transaction: GenServer.server(),
          log: GenServer.server()
        }

  defstruct [
    :buffers,
    :priority_cycle,
    :cycle_position,
    :on_envelope,
    :queue_worker
  ]

  @type t :: %__MODULE__{
          buffers: buffers(),
          priority_cycle: [Category.t()],
          cycle_position: non_neg_integer(),
          on_envelope: (Envelope.t() -> any()) | nil,
          queue_worker: GenServer.server() | nil
        }

  ## Public API

  @doc """
  Builds a priority cycle based on category weights.

  Returns a list of categories where each category appears a number of times
  equal to its priority weight.

  ## Examples

      iex> Sentry.Telemetry.Scheduler.build_priority_cycle()
      [:error, :error, :error, :error, :error, :check_in, :check_in, :check_in, :check_in, :transaction, :transaction, :transaction, :log, :log]

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
    * `:queue_worker` - QueueWorker server for transport concurrency control (optional)

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

  This is a blocking call that returns when all items have been processed.
  """
  @spec flush(GenServer.server()) :: :ok
  def flush(server) do
    GenServer.call(server, :flush)
  end

  ## GenServer Callbacks

  @impl true
  def init(opts) do
    buffers = Keyword.fetch!(opts, :buffers)
    weights = Keyword.get(opts, :weights)
    on_envelope = Keyword.get(opts, :on_envelope)
    queue_worker = Keyword.get(opts, :queue_worker)

    priority_cycle = build_priority_cycle(weights)

    state = %__MODULE__{
      buffers: buffers,
      priority_cycle: priority_cycle,
      cycle_position: 0,
      on_envelope: on_envelope,
      queue_worker: queue_worker
    }

    {:ok, state}
  end

  @impl true
  def handle_cast(:signal, %__MODULE__{} = state) do
    state = process_cycle(state)
    {:noreply, state}
  end

  @impl true
  def handle_call(:flush, _from, %__MODULE__{} = state) do
    state = flush_all_buffers(state)
    {:reply, :ok, state}
  end

  ## Private Functions

  defp process_cycle(%__MODULE__{} = state) do
    cycle_length = length(state.priority_cycle)
    max_attempts = cycle_length

    do_process_cycle(state, 0, max_attempts)
  end

  defp do_process_cycle(state, attempts, max_attempts) when attempts >= max_attempts do
    state
  end

  defp do_process_cycle(%__MODULE__{} = state, attempts, max_attempts) do
    if not transport_has_space?(state) do
      # Transport queue is full, stop processing. Items stay in buffers.
      state
    else
      category = Enum.at(state.priority_cycle, state.cycle_position)
      buffer = Map.fetch!(state.buffers, category)

      case Buffer.poll_if_ready(buffer) do
        {:ok, items} when items != [] ->
          send_items(state, category, items)
          state = advance_cycle(state)
          do_process_cycle(state, attempts + 1, max_attempts)

        _ ->
          state = advance_cycle(state)
          do_process_cycle(state, attempts + 1, max_attempts)
      end
    end
  end

  defp send_items(%{on_envelope: on_envelope} = state, :log, log_events) do
    # Apply before_send_log callback and filter out nil/false results
    processed_logs = apply_before_send_log_callbacks(log_events)

    if processed_logs != [] do
      # Skip test collection when on_envelope is set (used by unit tests)
      if is_nil(on_envelope) do
        case Sentry.Test.maybe_collect_logs(processed_logs) do
          :collected ->
            :ok

          :not_collecting ->
            envelope = Envelope.from_log_events(processed_logs)
            send_envelope(state, envelope)
        end
      else
        envelope = Envelope.from_log_events(processed_logs)
        send_envelope(state, envelope)
      end
    end
  end

  defp send_items(%{on_envelope: on_envelope} = state, category, items) do
    # Skip test collection when on_envelope is set (used by unit tests)
    if is_nil(on_envelope) do
      case try_collect_items(category, items) do
        :collected ->
          :ok

        :not_collecting ->
          envelope = build_envelope(category, items)
          send_envelope(state, envelope)
      end
    else
      envelope = build_envelope(category, items)
      send_envelope(state, envelope)
    end
  end

  defp flush_all_buffers(%__MODULE__{on_envelope: on_envelope} = state) do
    for {category, buffer} <- state.buffers do
      items = Buffer.drain(buffer)

      if items != [] do
        case category do
          :log ->
            # Apply before_send_log callback and filter out nil/false results
            processed_logs = apply_before_send_log_callbacks(items)

            if processed_logs != [] do
              if is_nil(on_envelope) do
                case Sentry.Test.maybe_collect_logs(processed_logs) do
                  :collected ->
                    :ok

                  :not_collecting ->
                    envelope = Envelope.from_log_events(processed_logs)
                    send_envelope_direct(state, envelope)
                end
              else
                envelope = Envelope.from_log_events(processed_logs)
                send_envelope_direct(state, envelope)
              end
            end

          _ ->
            for item <- items do
              if is_nil(on_envelope) do
                case try_collect_items(category, [item]) do
                  :collected ->
                    :ok

                  :not_collecting ->
                    envelope = build_envelope(category, [item])
                    send_envelope_direct(state, envelope)
                end
              else
                envelope = build_envelope(category, [item])
                send_envelope_direct(state, envelope)
              end
            end
        end
      end
    end

    state
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
  end

  defp call_before_send_log(log_event, {mod, fun}) do
    apply(mod, fun, [log_event])
  end

  defp try_collect_items(:error, [%Event{} = event | _]) do
    Sentry.Test.maybe_collect(event)
  end

  defp try_collect_items(:check_in, [%CheckIn{} = check_in | _]) do
    Sentry.Test.maybe_collect(check_in)
  end

  defp try_collect_items(:transaction, [%Transaction{} = tx | _]) do
    Sentry.Test.maybe_collect(tx)
  end

  defp try_collect_items(_category, _items) do
    :not_collecting
  end

  defp advance_cycle(%__MODULE__{} = state) do
    cycle_length = length(state.priority_cycle)
    new_position = rem(state.cycle_position + 1, cycle_length)
    %{state | cycle_position: new_position}
  end

  defp build_envelope(:error, [%Event{} = event | _rest]) do
    Envelope.from_event(event)
  end

  defp build_envelope(:check_in, [%CheckIn{} = check_in | _rest]) do
    Envelope.from_check_in(check_in)
  end

  defp build_envelope(:transaction, [%Transaction{} = tx | _rest]) do
    Envelope.from_transaction(tx)
  end

  defp build_envelope(:log, log_events) when is_list(log_events) do
    Envelope.from_log_events(log_events)
  end

  # Used during normal processing - routes through QueueWorker when available
  defp send_envelope(%__MODULE__{on_envelope: callback}, envelope)
       when is_function(callback, 1) do
    callback.(envelope)
  end

  defp send_envelope(%__MODULE__{on_envelope: nil, queue_worker: qw}, envelope)
       when not is_nil(qw) do
    QueueWorker.enqueue(qw, envelope)
  end

  defp send_envelope(%__MODULE__{on_envelope: nil, queue_worker: nil}, envelope) do
    send_direct(envelope)
  end

  # Used during flush - bypasses QueueWorker, sends directly or via callback
  defp send_envelope_direct(%__MODULE__{on_envelope: callback}, envelope)
       when is_function(callback, 1) do
    callback.(envelope)
  end

  defp send_envelope_direct(%__MODULE__{}, envelope) do
    send_direct(envelope)
  end

  defp send_direct(envelope) do
    client = Config.client()
    request_retries = Application.get_env(:sentry, :request_retries, Transport.default_retries())
    Transport.encode_and_post_envelope(envelope, client, request_retries)
  end

  defp transport_has_space?(%{on_envelope: cb}) when is_function(cb, 1), do: true
  defp transport_has_space?(%{queue_worker: nil}), do: true
  defp transport_has_space?(%{queue_worker: qw}), do: QueueWorker.has_space?(qw)

  defp default_weights do
    %{
      critical: Category.weight(:critical),
      high: Category.weight(:high),
      medium: Category.weight(:medium),
      low: Category.weight(:low)
    }
  end

  defp category_priority_mapping do
    [
      {:error, :critical},
      {:check_in, :high},
      {:transaction, :medium},
      {:log, :low}
    ]
  end
end
