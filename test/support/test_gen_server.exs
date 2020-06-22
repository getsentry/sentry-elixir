defmodule Sentry.TestGenServer do
  def start_link(pid) do
    GenServer.start_link(__MODULE__, pid)
  end

  def do_throw(pid) do
    send(pid, :throw)
  end

  def bad_exit(pid) do
    send(pid, :bad_exit)
  end

  def add_logger_metadata(pid, key, value) do
    send(pid, {:logger_metadata, key, value})
  end

  def add_sentry_breadcrumb(pid, value) do
    send(pid, {:sentry_breadcrumb, value})
  end

  def invalid_function(pid) do
    send(pid, :invalid_function)
  end

  def init(pid) do
    {:ok, pid}
  end

  def handle_call({:sleep, milliseconds}, _from, state) do
    :timer.sleep(milliseconds)
    {:reply, :ok, state}
  end

  def handle_info(:throw, _state) do
    throw("I am throwing")
  end

  def handle_info(:bad_exit, state) do
    {:stop, :bad_exit, state}
  end

  def handle_info({:logger_metadata, key, value}, state) do
    Logger.metadata([{key, value}])
    {:noreply, state}
  end

  def handle_info({:sentry_breadcrumb, value}, state) do
    Sentry.Context.add_breadcrumb(value)
    {:noreply, state}
  end

  def handle_info(:invalid_function, state) do
    cond do
      Version.match?(System.version(), ">= 1.5.0") ->
        NaiveDateTime.from_erl({}, {}, {})

      Version.match?(System.version(), "< 1.5.0") ->
        NaiveDateTime.from_erl({}, {})
    end

    {:ok, state}
  end

  def terminate(_, state) do
    send(state, "terminating")
  end
end
