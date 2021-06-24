defmodule Sentry.LoggerBackend do
  @moduledoc """
  Report Logger events like crashed processes to Sentry. To include in your
  application, start this backend in your application `start/2` callback:

      # lib/my_app/application.ex
      def start(_type, _args) do
        Logger.add_backend(Sentry.LoggerBackend)

  Sentry context will be included in metadata in reported events. Example:

      Sentry.Context.set_user_context(%{
        user_id: current_user.id
      })

  ## Configuration

  * `:excluded_domains` - Any messages with a domain in the configured
  list will not be sent. Defaults to `[:cowboy]` to avoid double reporting
  events from `Sentry.PlugCapture`.

  * `:metadata` - To include non-Sentry Logger metadata in reports, the
  `:metadata` key can be set to a list of keys. Metadata under those keys will
  be added in the `:extra` context under the `:logger_metadata` key. Defaults
  to `[]`.

  * `:level` - The minimum [Logger level](https://hexdocs.pm/logger/Logger.html#module-levels) to send events for.
  Defaults to `:error`.

  * `:capture_log_messages` - When `true`, this module will send all Logger
  messages. Defaults to `false`, which will only send messages with metadata
  that has the shape of an exception and stacktrace.

  Example:

      config :logger, Sentry.LoggerBackend,
        # Also send warn messages
        level: :warn,
        # Send messages from Plug/Cowboy
        excluded_domains: [],
        # Include metadata added with `Logger.metadata([foo_bar: "value"])`
        metadata: [:foo_bar],
        # Send messages like `Logger.error("error")` to Sentry
        capture_log_messages: true
  """
  @behaviour :gen_event

  defstruct level: :error, metadata: [], excluded_domains: [:cowboy], capture_log_messages: false

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
        level: elixir_logger_level_to_sentry_level(level),
        extra: %{logger_metadata: logger_metadata(meta, state), logger_level: level},
        result: :none
      ] ++ Map.to_list(sentry)

    case meta[:crash_reason] do
      {%_{__exception__: true} = exception, stacktrace} when is_list(stacktrace) ->
        Sentry.capture_exception(exception, [stacktrace: stacktrace] ++ opts)

      {other, stacktrace} when is_list(stacktrace) ->
        Sentry.capture_exception(
          Sentry.CrashError.exception(other),
          [stacktrace: stacktrace] ++ opts
        )

      _ ->
        if state.capture_log_messages do
          try do
            if is_binary(msg), do: msg, else: :unicode.characters_to_binary(msg)
          rescue
            _ -> :ok
          else
            msg -> Sentry.capture_message(msg, opts)
          end
        end
    end
  end

  defp get_sentry_from_callers([head | tail]) when is_pid(head) do
    with {:dictionary, [_ | _] = dictionary} <- :erlang.process_info(head, :dictionary),
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

  @spec elixir_logger_level_to_sentry_level(Logger.level()) :: String.t()
  defp elixir_logger_level_to_sentry_level(level) do
    case level do
      :emergency ->
        "fatal"

      :alert ->
        "fatal"

      :critical ->
        "fatal"

      :error ->
        "error"

      :warning ->
        "warning"

      :warn ->
        "warning"

      :notice ->
        "info"

      :info ->
        "info"

      :debug ->
        "debug"
    end
  end
end
