defmodule Sentry.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: Sentry.SenderRegistry},
      Sentry.SenderPool
    ]

    Supervisor.start_link(children, name: Sentry.Supervisor, strategy: :one_for_one)
  end
end
