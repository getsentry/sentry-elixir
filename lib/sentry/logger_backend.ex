defmodule Sentry.LoggerBackend do
  @moduledoc """
  Report logger events.

      config :logger,
        backends: [:console, BytepackWeb.SentryLoggerBackend]

  It sends all messages to Sentry, so it is recommended
  to disable Sentry for non-prod environments and set the
  log level to at least `:warn` in prod:

      config :logger, BytepackWeb.SentryLoggerBackend,
        level: :warn,
        metadata: [:foo_bar]

  You can add request metadata to the reports like this:

      SentryLoggerBackend.context(:request, %{ 
        url: Plug.Conn.request_url(conn),
        method: conn.method,
        query_string: conn.query_string,
        env: %{
          "SERVER_NAME" => conn.host,
          "SERVER_PORT" => conn.port,
          "REQUEST_ID" => Plug.Conn.get_resp_header(conn, request_id) |> List.first()
        }
      })

  You can add user metadata to the reports like this:

      SentryLoggerBackend.context(:user, %{
        user_id: current_user.id
      })

  """
  @behaviour :gen_event

  defstruct level: :warn, metadata: [], excluded_domains: [:cowboy]

  def context(key, value) when is_atom(key) and is_map(value) do
    {sentry, metadata} =
      case :logger.get_process_metadata() do
        %{sentry: sentry} = metadata -> {sentry, metadata}
        %{} = metadata -> {%{}, metadata}
        :undefined -> {%{}, %{}}
      end

    sentry = Map.update(sentry, key, value, &Map.merge(&1, value))
    :logger.set_process_metadata(Map.put(metadata, :sentry, sentry))
    :ok
  end

  def init(__MODULE__) do
    config = Application.get_env(:logger, __MODULE__, [])
    {:ok, struct(%__MODULE__{}, config)}
  end

  def init({__MODULE__, opts}) when is_list(opts) do
    config =
      Application.get_env(:logger, __MODULE__, [])
      |> Keyword.merge(opts)

    {:ok, struct(%__MODULE__{}, config)}
  end

  def handle_call({:configure, options}, state) do
    config =
      Application.get_env(:logger, __MODULE__, [])
      |> Keyword.merge(options)

    Application.put_env(:logger, __MODULE__, config)
    {:ok, :ok, struct(state, config)}
  end

  def handle_event({_level, gl, {Logger, _, _, _}}, state) when node(gl) != node() do
    {:ok, state}
  end

  def handle_event({level, _gl, {Logger, msg, _ts, meta}}, state) do
    if Logger.compare_levels(level, state.level) != :lt and
         not excluded_domain?(meta[:domain], state) do
      log(level, msg, meta, state)
    end

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

  defp log(level, msg, meta, state) do
    sentry = meta[:sentry] || get_sentry_from_callers(meta[:callers] || [])

    opts =
      [
        event_source: :logger,
        extra: %{logger_metadata: logger_metadata(meta, state), logger_level: level},
        result: :none
      ] ++ Map.to_list(sentry)

    case meta[:crash_reason] do
      {%_{__exception__: true} = exception, stacktrace} when is_list(stacktrace) ->
        Sentry.capture_exception(exception, [stacktrace: stacktrace] ++ opts)

      _ ->
        # TODO: Make this opt-in or opt-out
        try do
          if is_binary(msg), do: msg, else: :unicode.characters_to_binary(msg)
        rescue
          _ -> :ok
        else
          msg -> Sentry.capture_message(msg, opts)
        end
    end
  end

  defp get_sentry_from_callers([head | tail]) do
    with [_ | _] = dictionary <- :erlang.process_info(head, :dictionary),
         %{sentry: sentry} <- dictionary[:"$logger_metadata$"] do
      sentry
    else
      _ -> get_sentry_from_callers(tail)
    end
  end

  defp get_sentry_from_callers(_), do: %{}

  defp excluded_domain?([head | _], state), do: head in state.excluded_domains
  defp excluded_domain?(_, _), do: false

  defp logger_metadata(meta, state) do
    for key <- state.metadata,
        value = meta[key],
        do: {key, value},
        into: %{}
  end
end
