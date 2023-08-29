defmodule Sentry.SenderPool do
  use Supervisor

  def start_link([] = _opts) do
    Supervisor.start_link(__MODULE__, [])
  end

  @impl true
  def init([]) do
    pool_size = max(System.schedulers_online(), 8)

    Application.put_env(:sentry, :sender_pool_size, pool_size)

    children =
      for index <- 1..pool_size do
        Supervisor.child_spec({Sentry.Sender, []}, id: {Sentry.Sender, index})
      end

    Supervisor.init(children, strategy: :one_for_one)
  end
end
