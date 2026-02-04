defmodule Sentry.TelemetryProcessor do
  @moduledoc """
  Supervisor managing telemetry buffers and scheduler for the Sentry SDK.

  The TelemetryProcessor is the central coordinator for all telemetry data
  flowing through the SDK. It manages four category-specific ring buffers
  (Error, Transaction, CheckIn, Log) coordinated by a weighted round-robin
  scheduler that prioritizes critical telemetry.

  ## Architecture

  The processor starts as a supervisor with the following children:

    * Error Buffer - for error events (critical priority)
    * CheckIn Buffer - for cron check-ins (high priority)
    * Transaction Buffer - for performance transactions (medium priority)
    * Log Buffer - for log entries (low priority)
    * Scheduler - weighted round-robin scheduler processing all buffers

  ## Priority Weights

  Under load, critical telemetry gets priority:

    * `:critical` - weight 5 (errors)
    * `:high` - weight 4 (check-ins)
    * `:medium` - weight 3 (transactions)
    * `:low` - weight 2 (logs)

  ## Usage

      # Add items - they're routed to the correct buffer by type
      TelemetryProcessor.add(processor, %Sentry.Event{...})
      TelemetryProcessor.add(processor, %Sentry.CheckIn{...})
      TelemetryProcessor.add(processor, %Sentry.LogEvent{...})

      # Flush all pending items
      TelemetryProcessor.flush(processor)

  """
  @moduledoc since: "11.0.0"

  use Supervisor

  alias Sentry.Telemetry.{Buffer, Category, Scheduler}
  alias Sentry.Transport.QueueWorker
  alias Sentry.{Event, CheckIn, Transaction, LogEvent}

  @default_name __MODULE__

  @type option ::
          {:name, atom()}
          | {:buffer_capacities, %{Category.t() => pos_integer()}}
          | {:buffer_configs, %{Category.t() => map()}}
          | {:scheduler_weights, %{Category.priority() => pos_integer()}}
          | {:on_envelope, (Sentry.Envelope.t() -> any())}
          | {:transport_capacity, pos_integer()}

  ## Public API

  @doc """
  Returns the default processor name.
  """
  @spec default_name() :: atom()
  def default_name, do: @default_name

  @doc """
  Starts the TelemetryProcessor supervisor.

  ## Options

    * `:name` - Name to register the supervisor under (defaults to `#{inspect(@default_name)}`)
    * `:buffer_capacities` - Map of category to capacity override (optional)
    * `:buffer_configs` - Map of category to config map with `:capacity`, `:batch_size`, `:timeout` (optional)
    * `:scheduler_weights` - Map of priority to weight override (optional)
    * `:on_envelope` - Callback function invoked when envelopes are ready to send (optional)
    * `:transport_capacity` - Maximum number of envelopes the transport queue can hold (default: 1000)

  ## Examples

      TelemetryProcessor.start_link()

      TelemetryProcessor.start_link(
        buffer_capacities: %{error: 200, log: 2000},
        scheduler_weights: %{critical: 10, high: 5, medium: 3, low: 1}
      )

  """
  @spec start_link([option()]) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, @default_name)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Adds an item to the appropriate buffer based on its type.

  Uses the processor from process dictionary or the default (`#{inspect(@default_name)}`).
  See `add/2` for the version accepting a custom processor.

  Returns `:ok`.
  """
  @spec add(Event.t() | CheckIn.t() | Transaction.t() | LogEvent.t()) :: :ok
  def add(item) do
    add(processor_name(), item)
  end

  @doc """
  Adds an item to the appropriate buffer based on its type.

  The item is routed based on pattern matching:

    * `%Event{}` → error buffer
    * `%CheckIn{}` → check_in buffer
    * `%Transaction{}` → transaction buffer
    * `%LogEvent{}` → log buffer

  After adding, the scheduler is signaled to wake and process items.

  Returns `:ok`.
  """
  @spec add(Supervisor.supervisor(), Event.t() | CheckIn.t() | Transaction.t() | LogEvent.t()) ::
          :ok
  def add(processor, item) do
    category = item_to_category(item)
    buffer = get_buffer(processor, category)
    Buffer.add(buffer, item)
    signal_scheduler(processor)
    :ok
  end

  @doc """
  Flushes all buffers by draining their contents and sending all items.

  Uses the processor from process dictionary or the default (`#{inspect(@default_name)}`).
  This is a blocking call that returns when all items have been processed.
  """
  @spec flush() :: :ok
  def flush do
    flush(processor_name())
  end

  @doc """
  Flushes all buffers by draining their contents and sending all items.

  This is a blocking call that returns when all items have been processed.
  The optional timeout specifies how long to wait (default: 5000ms).
  """
  @spec flush(Supervisor.supervisor(), timeout()) :: :ok
  def flush(processor, timeout \\ 5000) do
    scheduler = get_scheduler(processor)
    Scheduler.flush(scheduler)
    queue_worker = get_queue_worker(processor)
    QueueWorker.flush(queue_worker, timeout)
  end

  @doc """
  Returns the buffer pid for a given category.
  """
  @spec get_buffer(Supervisor.supervisor(), Category.t()) :: pid()
  def get_buffer(processor, category) when category in [:error, :check_in, :transaction, :log] do
    children = Supervisor.which_children(processor)
    buffer_id = buffer_id(category)

    case List.keyfind(children, buffer_id, 0) do
      {^buffer_id, pid, :worker, _} when is_pid(pid) -> pid
      _ -> raise "Buffer not found for category: #{category}"
    end
  end

  @doc """
  Returns the scheduler pid.
  """
  @spec get_scheduler(Supervisor.supervisor()) :: pid()
  def get_scheduler(processor) do
    children = Supervisor.which_children(processor)

    case List.keyfind(children, :scheduler, 0) do
      {:scheduler, pid, :worker, _} when is_pid(pid) -> pid
      _ -> raise "Scheduler not found"
    end
  end

  @doc """
  Returns the queue worker pid.
  """
  @spec get_queue_worker(Supervisor.supervisor()) :: pid()
  def get_queue_worker(processor) do
    children = Supervisor.which_children(processor)

    case List.keyfind(children, :queue_worker, 0) do
      {:queue_worker, pid, :worker, _} when is_pid(pid) -> pid
      _ -> raise "QueueWorker not found"
    end
  end

  @doc """
  Returns the current size of a buffer for a given category.

  Uses the processor from process dictionary or the default.
  Returns 0 if the processor is not running.
  """
  @spec buffer_size(Category.t()) :: non_neg_integer()
  def buffer_size(category) when category in [:error, :check_in, :transaction, :log] do
    buffer_size(processor_name(), category)
  end

  @doc """
  Returns the current size of a buffer for a given category.

  Returns 0 if the processor is not running.
  """
  @spec buffer_size(Supervisor.supervisor(), Category.t()) :: non_neg_integer()
  def buffer_size(processor, category) when category in [:error, :check_in, :transaction, :log] do
    case safe_get_buffer(processor, category) do
      {:ok, buffer} -> Buffer.size(buffer)
      :error -> 0
    end
  end

  defp safe_get_buffer(processor, category) do
    try do
      {:ok, get_buffer(processor, category)}
    catch
      :exit, _ -> :error
    end
  end

  ## Supervisor Callbacks

  @impl true
  def init(opts) do
    buffer_capacities = Keyword.get(opts, :buffer_capacities, %{})
    buffer_configs = Keyword.get(opts, :buffer_configs, %{})
    scheduler_weights = Keyword.get(opts, :scheduler_weights)
    on_envelope = Keyword.get(opts, :on_envelope)
    transport_capacity = Keyword.get(opts, :transport_capacity, 1000)

    # Generate unique suffix for this processor instance
    uid = System.unique_integer([:positive])

    # Build buffer specs for each category with unique names
    buffer_names =
      for category <- Category.all(), into: %{} do
        {category, :"sentry_buffer_#{category}_#{uid}"}
      end

    buffer_specs =
      for category <- Category.all() do
        config = build_buffer_config(category, buffer_capacities, buffer_configs)

        %{
          id: buffer_id(category),
          start:
            {Buffer, :start_link,
             [
               [
                 category: category,
                 name: Map.fetch!(buffer_names, category),
                 capacity: config.capacity,
                 batch_size: config.batch_size,
                 timeout: config.timeout
               ]
             ]}
        }
      end

    # QueueWorker for transport concurrency control
    queue_worker_name = :"sentry_queue_worker_#{uid}"

    queue_worker_spec = %{
      id: :queue_worker,
      start: {QueueWorker, :start_link, [[name: queue_worker_name, capacity: transport_capacity]]}
    }

    # Scheduler uses the named buffers and queue worker
    scheduler_opts =
      [
        buffers: %{
          error: Map.fetch!(buffer_names, :error),
          check_in: Map.fetch!(buffer_names, :check_in),
          transaction: Map.fetch!(buffer_names, :transaction),
          log: Map.fetch!(buffer_names, :log)
        },
        queue_worker: queue_worker_name
      ]
      |> maybe_add_opt(:weights, scheduler_weights)
      |> maybe_add_opt(:on_envelope, on_envelope)

    scheduler_spec = %{
      id: :scheduler,
      start: {Scheduler, :start_link, [scheduler_opts]}
    }

    children = buffer_specs ++ [queue_worker_spec, scheduler_spec]

    Supervisor.init(children, strategy: :one_for_one)
  end

  ## Private Functions

  defp item_to_category(%Event{}), do: :error
  defp item_to_category(%CheckIn{}), do: :check_in
  defp item_to_category(%Transaction{}), do: :transaction
  defp item_to_category(%LogEvent{}), do: :log

  defp buffer_id(:error), do: :error_buffer
  defp buffer_id(:check_in), do: :check_in_buffer
  defp buffer_id(:transaction), do: :transaction_buffer
  defp buffer_id(:log), do: :log_buffer

  defp build_buffer_config(category, capacities, configs) do
    defaults = Category.default_config(category)

    # First apply capacity override
    config =
      case Map.get(capacities, category) do
        nil -> defaults
        capacity -> Map.put(defaults, :capacity, capacity)
      end

    # Then apply full config override
    case Map.get(configs, category) do
      nil -> config
      category_config -> Map.merge(config, category_config)
    end
  end

  defp signal_scheduler(processor) do
    scheduler = get_scheduler(processor)
    Scheduler.signal(scheduler)
  end

  defp processor_name do
    Process.get(:sentry_telemetry_processor, @default_name)
  end

  defp maybe_add_opt(opts, _key, nil), do: opts
  defp maybe_add_opt(opts, key, value), do: Keyword.put(opts, key, value)
end
