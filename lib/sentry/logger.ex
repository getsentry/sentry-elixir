defmodule Sentry.Logger do
  require Logger
  @moduledoc """
    Use this if you'd like to capture all Error messages that the Plug handler might not. Simply set `use_error_logger` to true. 

    This is based on the Erlang [error_logger](http://erlang.org/doc/man/error_logger.html).

    ```elixir
    config :sentry,
      use_error_logger: true
    ```
  """

  use GenEvent

  def init(_mod, []), do: {:ok, []}

  def handle_call({:configure, new_keys}, _state) do
    {:ok, :ok, new_keys}
  end

  def handle_event({_level, gl, _event}, state) when node(gl) != node() do
    {:ok, state}
  end

  def handle_event({:error_report, _gl, {_pid, _type, [message | _]}}, state) when is_list(message) do
    try do
      error_info = message[:error_info]
      context = get_in(message, [:dictionary, :sentry_context]) || %{}
      opts = context 
        |> Map.take(Sentry.Context.context_keys) 
        |> Map.to_list()

      case error_info do
        {_kind, {exception, stacktrace}, _stack} when is_list(stacktrace) ->
          opts = Keyword.put(opts, :stacktrace, stacktrace)
          |> Keyword.put(:event_source, :logger)
          Sentry.capture_exception(exception, opts)
        {_kind, exception, stacktrace} ->
          opts = Keyword.put(opts, :stacktrace, stacktrace)
          |> Keyword.put(:event_source, :logger)
          Sentry.capture_exception(exception, opts)
      end
    rescue
      ex ->
        error_type = strip_elixir_prefix(ex.__struct__)
        reason = Exception.message(ex)
        message = "Unable to notify Sentry! #{error_type}: #{reason}"
        Logger.warn(message)
    end

    {:ok, state}
  end

  def handle_event({_level, _gl, _event}, state) do
    {:ok, state}
  end

  @doc """
    Internally all modules are prefixed with Elixir. This function removes the
    Elixir prefix from the module when it is converted to a string.
  """
  def strip_elixir_prefix(module) do
    module
    |> Atom.to_string
    |> String.split(".")
    |> tl
    |> Enum.join(".")
  end
end
