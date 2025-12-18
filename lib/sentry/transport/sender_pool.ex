defmodule Sentry.Transport.SenderPool do
  @moduledoc false

  use Supervisor

  @queued_events_key {__MODULE__, :queued_events}
  @queued_transactions_key {__MODULE__, :queued_transactions}

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link([] = _opts) do
    Supervisor.start_link(__MODULE__, [])
  end

  @impl true
  def init([]) do
    queued_events_counter = :counters.new(1, [])
    :persistent_term.put(@queued_events_key, queued_events_counter)

    queued_transactions_counter = :counters.new(1, [])
    :persistent_term.put(@queued_transactions_key, queued_transactions_counter)

    children =
      for index <- 1..pool_size() do
        Supervisor.child_spec({Sentry.Transport.Sender, index: index},
          id: {Sentry.Transport.Sender, index}
        )
      end

    Supervisor.init(children, strategy: :one_for_one)
  end

  @spec pool_size() :: pos_integer()
  def pool_size do
    if pool_size = :persistent_term.get({:sentry, :sender_pool_size}, nil) do
      pool_size
    else
      value = max(System.schedulers_online(), 8)
      :persistent_term.put({:sentry, :sender_pool_size}, value)
      value
    end
  end

  # Returns the key used, so callers can pass it to decrease_* later
  @spec increase_queued_events_counter() :: term()
  def increase_queued_events_counter do
    key = queued_events_key()
    counter = :persistent_term.get(key)
    :counters.add(counter, 1, 1)
    key
  end

  @spec increase_queued_transactions_counter() :: term()
  def increase_queued_transactions_counter do
    key = queued_transactions_key()
    counter = :persistent_term.get(key)
    :counters.add(counter, 1, 1)
    key
  end

  # Accept optional key to decrement the correct counter (used by Sender)
  @spec decrease_queued_events_counter(term()) :: :ok
  def decrease_queued_events_counter(key \\ nil) do
    key = key || queued_events_key()
    counter = :persistent_term.get(key)
    :counters.sub(counter, 1, 1)
  end

  @spec decrease_queued_transactions_counter(term()) :: :ok
  def decrease_queued_transactions_counter(key \\ nil) do
    key = key || queued_transactions_key()
    counter = :persistent_term.get(key)
    :counters.sub(counter, 1, 1)
  end

  @spec get_queued_events_counter() :: non_neg_integer()
  def get_queued_events_counter do
    counter = :persistent_term.get(queued_events_key())
    :counters.get(counter, 1)
  end

  # Allow per-process override of counter keys (for test isolation)
  defp queued_events_key do
    Process.get(:sentry_queued_events_key, @queued_events_key)
  end

  defp queued_transactions_key do
    Process.get(:sentry_queued_transactions_key, @queued_transactions_key)
  end
end
