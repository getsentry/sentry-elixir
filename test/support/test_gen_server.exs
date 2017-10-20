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

  def invalid_function(pid) do
    send(pid, :invalid_function)
  end

  def init(pid) do
    {:ok, pid}
  end

  def handle_info(:throw, _state) do
    throw("I am throwing")
  end

  def handle_info(:bad_exit, state) do
    {:stop, :bad_exit, state}
  end

  def handle_info(:invalid_function, state) do
    cond do
      Version.match?(System.version, ">= 1.5.0") ->
        NaiveDateTime.from_erl({}, {}, {})
      Version.match?(System.version, "< 1.5.0") ->
        NaiveDateTime.from_erl({}, {})
    end
    {:ok, state}
  end

  def terminate(_, state) do
    send(state, "terminating")
  end
end

