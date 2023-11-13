defmodule Sentry.TestGenServer do
  use GenServer

  def start_link(test_pid \\ self()) do
    GenServer.start_link(__MODULE__, test_pid)
  end

  def run(server, fun, timeout \\ :infinity) do
    GenServer.call(server, {:run, fun}, timeout)
  end

  def run_async(server, fun) do
    GenServer.cast(server, {:run_async, fun})
  end

  @impl true
  def init(test_pid), do: {:ok, test_pid}

  @impl true
  def handle_call({:run, fun}, _from, _state), do: fun.()

  @impl true
  def handle_cast({:run_async, fun}, state), do: fun.(state)
end
