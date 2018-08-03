defmodule Sentry.LoggerBackend do
  @moduledoc """
  This module makes use of Elixir 1.7's new Logger metadata to report
  crashes processes.  It replaces the previous `Sentry.Logger` sytem.
  """
  @behaviour :gen_event

  defstruct level: nil

  def init(__MODULE__) do
    config = Application.get_env(:logger, :sentry, [])
    {:ok, init(config, %__MODULE__{})}
  end

  def init({__MODULE__, opts}) when is_list(opts) do
    config =
      Application.get_env(:logger, :sentry, [])
      |> Keyword.merge(opts)

    {:ok, init(config, %__MODULE__{})}
  end

  def handle_call({:configure, _options}, state) do
    {:ok, :ok, state}
  end

  def handle_event({_level, gl, {Logger, _, _, _}}, state) when node(gl) != node() do
    {:ok, state}
  end

  def handle_event({_level, _gl, {Logger, _msg, _ts, meta}}, state) do
    case Keyword.get(meta, :crash_reason) do
      {reason, stacktrace} ->
        opts =
          Keyword.put([], :event_source, :logger)
          |> Keyword.put(:stacktrace, stacktrace)

        Sentry.capture_exception(reason, opts)

      reason when is_atom(reason) ->
        Sentry.capture_exception(reason, event_source: :logger)

      _ ->
        :ok
    end

    {:ok, state}
  end

  def handle_event(:flush, state) do
    {:ok, state}
  end

  def handle_event(_, state) do
    {:ok, state}
  end

  def handle_info(_, state) do
    {:ok, state}
  end

  def code_change(_old_vsn, state, _extra) do
    {:ok, state}
  end

  def terminate(_reason, _state) do
    :ok
  end

  defp init(config, %__MODULE__{} = state) do
    level = Keyword.get(config, :level)
    %{state | level: level}
  end
end
