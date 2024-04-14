defmodule Sentry.LoggerHandler.RateLimiter do
  @moduledoc false

  # A generic rate-limiter implemented on top of :atomics (requires OTP 21.2+).
  # Allows you to rate limit to N events every M milliseconds.

  use GenServer

  @type id() :: :logger.handler_id()

  @atomics_index 1

  ## Public API

  @spec start_under_sentry_supervisor(id(), keyword()) :: Supervisor.on_start_child()
  def start_under_sentry_supervisor(id, options) when is_atom(id) and is_list(options) do
    max_events = Keyword.fetch!(options, :max_events)
    interval = Keyword.fetch!(options, :interval)

    spec = Supervisor.child_spec(child_spec({id, max_events, interval}), id: {__MODULE__, id})

    case Supervisor.start_child(Sentry.Supervisor, spec) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec terminate_and_delete(id()) :: :ok
  def terminate_and_delete(id) when is_atom(id) do
    _ = Supervisor.terminate_child(Sentry.Supervisor, child_id(id))
    _ = Supervisor.delete_child(Sentry.Supervisor, child_id(id))
    :ok
  end

  @spec start_link({id(), non_neg_integer(), non_neg_integer()}) :: GenServer.on_start()
  def start_link({id, max_events, interval}) do
    GenServer.start_link(__MODULE__, {id, max_events, interval})
  end

  @spec increment(id()) :: :ok | :rate_limited
  def increment(id) when is_atom(id) do
    {atomics_ref, max_events} = :persistent_term.get(persistent_term_key(id))
    value = :atomics.add_get(atomics_ref, @atomics_index, _incr = 1)

    if value > max_events do
      :rate_limited
    else
      :ok
    end
  end

  ## Callbacks

  @impl GenServer
  def init({id, max_events, interval}) do
    atomics_ref = :atomics.new(_size = 1, signed: false)
    :persistent_term.put(persistent_term_key(id), {atomics_ref, max_events})
    _ = :timer.send_interval(interval, :tick)
    {:ok, id}
  end

  @impl GenServer
  def handle_info(:tick, id) do
    {atomics_ref, _max_events} = :persistent_term.get(persistent_term_key(id))
    :ok = :atomics.put(atomics_ref, @atomics_index, 0)
    {:noreply, id}
  end

  @compile {:inline, persistent_term_key: 1}
  defp persistent_term_key(id), do: {__MODULE__, id}

  defp child_id(id), do: {__MODULE__, id}
end
