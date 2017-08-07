defmodule Sentry.Logger do
  require Logger
  @moduledoc """
  This is based on the Erlang [error_logger](http://erlang.org/doc/man/error_logger.html).

  To set this up, add `:ok = :error_logger.add_report_handler(Sentry.Logger)` to your application's start function. Example:

  ```elixir
  def start(_type, _opts) do
    children = [
      supervisor(Task.Supervisor, [[name: Sentry.TaskSupervisor]]),
      :hackney_pool.child_spec(Sentry.Client.hackney_pool_name(),  [timeout: Config.hackney_timeout(), max_connections: Config.max_hackney_connections()])
    ]
    opts = [strategy: :one_for_one, name: Sentry.Supervisor]

    :ok = :error_logger.add_report_handler(Sentry.Logger)

    Supervisor.start_link(children, opts)
  end
  ```
  """

  use GenEvent

  def init(_mod, []), do: {:ok, []}

  def handle_call({:configure, new_keys}, _state), do: {:ok, :ok, new_keys}

  def handle_event({_level, gl, _event}, state) when node(gl) != node() do
    {:ok, state}
  end

  def handle_event({:error_report, _gl, {_pid, _type, [message | _]}}, state) when is_list(message) do
    try do
      {kind, exception, stacktrace, module} = get_exception_and_stacktrace(message[:error_info])
                                      |> get_initial_call_and_module(message)

      opts = (get_in(message, ~w[dictionary sentry_context]a) || %{})
             |> Map.take(Sentry.Context.context_keys)
             |> Map.to_list()
             |> Keyword.put(:event_source, :logger)
             |> Keyword.put(:stacktrace, stacktrace)
             |> Keyword.put(:error_type, kind)
             |> Keyword.put(:module, module)

      Sentry.capture_exception(exception, opts)
    rescue ex ->
      Logger.warn(fn -> "Unable to notify Sentry due to #{inspect(ex)}! #{inspect(message)}" end)
    end

    {:ok, state}
  end

  def handle_event(_, state) do
    {:ok, state}
  end


  defp get_exception_and_stacktrace({kind, {exception, sub_stack}, _stack}) when is_list(sub_stack) do
    {kind, exception, sub_stack}
  end
  defp get_exception_and_stacktrace({kind, exception, stacktrace}) do
    {kind, exception, stacktrace}
  end

  # GenServer exits will usually only report a stacktrace containing core
  # GenServer functions, which causes Sentry to group unrelated exits
  # together.  This gets the `:initial_call` to help disambiguate, as it contains
  # the MFA for how the GenServer was started.
  defp get_initial_call_and_module({kind, exception, stacktrace}, error_info) do
    case Keyword.get(error_info, :initial_call) do
      {module, function, arg} ->
        {kind, exception, stacktrace ++ [{module, function, arg, []}], module}
        _ ->
          {kind, exception, stacktrace, nil}
    end
  end
end
