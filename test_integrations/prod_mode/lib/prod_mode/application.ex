defmodule ProdMode.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    ProdMode.Callback.init_table()
    Supervisor.start_link([], strategy: :one_for_one, name: ProdMode.Supervisor)
  end
end
