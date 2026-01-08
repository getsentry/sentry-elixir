defmodule Sentry.LogEventBuffer do
  @moduledoc false
  # Internal module for buffering log events before sending them to Sentry.
  #
  # This module is responsible for:
  # - Buffering log events in memory
  # - Flushing events when the buffer is full or after a timeout
  # - Managing the lifecycle of the buffer process
  #
  # Per the Sentry Logs Protocol spec:
  # - Events are flushed when buffer reaches max_events (default 100) OR every 5 seconds
  # - Maximum of 1000 events can be queued to prevent memory issues

  use GenServer
  require Logger

  alias Sentry.{Config, LogEvent}

  @flush_interval_ms 5_000
  @max_queue_size 1_000

  @typedoc false
  @type state :: %{
          events: [LogEvent.t()],
          max_events: non_neg_integer(),
          timer_ref: reference() | nil
        }

  ## Public API

  @doc """
  Starts the log event buffer process.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Adds a log event to the buffer.

  If the buffer is full (max_queue_size reached), the event is dropped.
  If the buffer reaches max_events, it is flushed immediately.

  In test mode with collection enabled, logs are collected immediately
  and not added to the buffer.
  """
  @spec add_event(LogEvent.t()) :: :ok
  def add_event(%LogEvent{} = event) do
    # In test mode, try to collect immediately before buffering
    # This ensures the caller chain is preserved for Sentry.Test collection
    case Sentry.Test.maybe_collect_logs([event]) do
      :collected ->
        :ok

      :not_collecting ->
        GenServer.cast(__MODULE__, {:add_event, event})
    end
  end

  @doc """
  Flushes all buffered events immediately.
  """
  @spec flush() :: :ok
  def flush do
    GenServer.call(__MODULE__, :flush)
  end

  @doc """
  Returns the current number of buffered events.
  """
  @spec size() :: non_neg_integer()
  def size do
    GenServer.call(__MODULE__, :size)
  end

  ## GenServer callbacks

  @impl GenServer
  def init(opts) do
    max_events = Keyword.get(opts, :max_events, Config.max_log_events())

    state = %{
      events: [],
      max_events: max_events,
      timer_ref: schedule_flush()
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_cast({:add_event, event}, state) do
    # Check if queue is at max capacity
    if length(state.events) >= @max_queue_size do
      # Drop the event to prevent memory issues
      log_warning("Log event buffer is full (#{@max_queue_size} events), dropping event")
      {:noreply, state}
    else
      events = [event | state.events]

      if length(events) >= state.max_events do
        # Flush immediately if we've reached max_events
        send_events(events)
        cancel_timer(state.timer_ref)
        {:noreply, %{state | events: [], timer_ref: schedule_flush()}}
      else
        {:noreply, %{state | events: events}}
      end
    end
  end

  @impl GenServer
  def handle_call(:flush, _from, state) do
    send_events(state.events)
    cancel_timer(state.timer_ref)
    flush_stale_timeout_message()
    {:reply, :ok, %{state | events: [], timer_ref: schedule_flush()}}
  end

  @impl GenServer
  def handle_call(:size, _from, state) do
    {:reply, length(state.events), state}
  end

  @impl GenServer
  def handle_info(:flush_timeout, state) do
    if state.events != [] do
      send_events(state.events)
    end

    {:noreply, %{state | events: [], timer_ref: schedule_flush()}}
  end

  @impl GenServer
  def terminate(_reason, state) do
    # Flush any remaining events on shutdown
    if state.events != [] do
      send_events(state.events)
    end

    :ok
  end

  ## Private helpers

  defp schedule_flush do
    Process.send_after(self(), :flush_timeout, @flush_interval_ms)
  end

  defp cancel_timer(nil), do: :ok

  defp cancel_timer(timer_ref) do
    _ = Process.cancel_timer(timer_ref)
    :ok
  end

  # Flush any stale :flush_timeout message that may be in the queue.
  # This can happen if the timer fires while we're in the middle of a flush.
  defp flush_stale_timeout_message do
    receive do
      :flush_timeout -> :ok
    after
      0 -> :ok
    end
  end

  defp log_warning(message) do
    level = Config.log_level()

    if Logger.compare_levels(level, :warning) != :lt do
      Logger.warning(message, domain: [:sentry])
    end
  end

  defp log_debug(message) do
    level = Config.log_level()

    if Logger.compare_levels(level, :debug) != :lt do
      Logger.debug(message, domain: [:sentry])
    end
  end

  defp send_events([]), do: :ok

  defp send_events(events) do
    events = Enum.reverse(events)

    log_debug("[LogEventBuffer] Sending #{length(events)} log events to Sentry")

    # In test mode, send synchronously so tests can collect logs immediately
    _ =
      if Config.test_mode?() do
        do_send_events(events)
      else
        # Send asynchronously via Task.Supervisor to avoid blocking and prevent unbounded task spawning
        Task.Supervisor.start_child(__MODULE__.TaskSupervisor, fn -> do_send_events(events) end)
      end

    :ok
  end

  defp do_send_events(events) do
    case Sentry.Client.send_log_events(events) do
      {:ok, envelope_id} ->
        log_debug(
          "[LogEventBuffer] Successfully sent #{length(events)} log events (envelope_id: #{envelope_id})"
        )

        :ok

      {:error, reason} ->
        log_warning("[LogEventBuffer] Failed to send log events: #{inspect(reason)}")
        :ok
    end
  end
end
