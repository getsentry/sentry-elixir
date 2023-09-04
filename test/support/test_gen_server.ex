defmodule Sentry.TestGenServer do
  use GenServer

  import Kernel, except: [throw: 1, exit: 1]

  def start_link(test_pid \\ self()) do
    GenServer.start_link(__MODULE__, test_pid)
  end

  def throw(server) do
    GenServer.cast(server, :throw)
  end

  def exit(server) do
    GenServer.cast(server, :exit)
  end

  def add_logger_metadata(server, key, value) do
    GenServer.cast(server, {:logger_metadata, key, value})
  end

  def add_sentry_breadcrumb(server, value) do
    GenServer.cast(server, {:sentry_breadcrumb, value})
  end

  def invalid_function(server) do
    GenServer.cast(server, :invalid_function)
  end

  def sleep(server, timeout) do
    GenServer.call(server, :sleep, timeout)
  end

  @impl true
  def init(test_pid) do
    {:ok, test_pid}
  end

  @impl true
  def handle_call(:sleep, _from, state) do
    Process.sleep(:infinity)
    {:reply, :ok, state}
  end

  @impl true
  def handle_cast(cast, state)

  def handle_cast(:throw, _state) do
    Kernel.throw("I am throwing")
  end

  def handle_cast(:exit, state) do
    {:stop, :bad_exit, state}
  end

  def handle_cast({:logger_metadata, key, value}, state) do
    Logger.metadata([{key, value}])
    {:noreply, state}
  end

  def handle_cast({:sentry_breadcrumb, value}, state) do
    Sentry.Context.add_breadcrumb(value)
    {:noreply, state}
  end

  def handle_cast(:invalid_function, state) do
    apply(NaiveDateTime, :from_erl, [{}, {}, {}])
    {:noreply, state}
  end
end
