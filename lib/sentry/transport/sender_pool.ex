defmodule Sentry.Transport.SenderPool do
  @moduledoc false

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link([] = _opts) do
    Supervisor.start_link(__MODULE__, [])
  end

  @impl true
  def init([]) do
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
end
