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

  def handle_call({:configure, new_keys}, _state), do: {:ok, :ok, new_keys}

  def handle_event({_level, gl, _event}, state) when node(gl) != node() do
    {:ok, state}
  end

  def handle_event({:error_report, gl, {_pid, _type, [message | _]}}, state) when is_list(message) do
    try do
      {exception, stacktrace} = get_exception_and_stacktrace(message[:error_info])

      opts = get_in(message, ~w[dictionary sentry_context]a) || %{}
             |> Map.take(Sentry.Context.context_keys)
             |> Map.to_list()
             |> Keyword.put(:event_source, :logger)
             |> Keyword.put(:stacktrace, stacktrace)

      Sentry.capture_exception(exception, opts)
    rescue ex ->
      error_type = strip_elixir_prefix(ex.__struct__)
      reason = Exception.message(ex)
      Logger.warn("Unable to notify Sentry! #{error_type}: #{reason}")
    end

    {:ok, state}
  end
  def handle_event({_level, _gl, _event}, state), do: {:ok, state}

  defp get_exception_and_stacktrace({_kind, {exception, stacktrace}, _stack}), do: {exception, stacktrace}
  defp get_exception_and_stacktrace({_kind, exception, stacktrace}), do: {exception, stacktrace}

  @doc """
  Internally all modules are prefixed with Elixir. This function removes the
  Elixir prefix from the module when it is converted to a string.
  """
  @spec strip_elixir_prefix(module :: atom()) :: bitstring()
  def strip_elixir_prefix(module) do
    module
    |> Atom.to_string
    |> String.split(".")
    |> tl
    |> Enum.join(".")
  end
end
