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
  to `[]`. If set to `:all`, all metadata will be included. `:all` is available
  since v9.0.0 of this library.

  * `:level` - The minimum [Logger level](https://hexdocs.pm/logger/Logger.html#module-levels
    to send events for. Defaults to `:error`.

  * `:capture_log_messages` - When `true`, this module will send all Logger
  messages. Defaults to `false`, which will only send messages with metadata
  that has the shape of an exception and stacktrace.

  Example:

      config :logger, Sentry.LoggerBackend,
        # Also send warning messages
        level: :warning,
        # Send messages from Plug/Cowboy
        excluded_domains: [],
        # Include metadata added with `Logger.metadata([foo_bar: "value"])`
        metadata: [:foo_bar],
        # Send messages like `Logger.error("error")` to Sentry
        capture_log_messages: true

  """

  @behaviour :gen_event

  alias Sentry.LoggerUtils

  ## State

  defstruct level: :error, metadata: [], excluded_domains: [:cowboy], capture_log_messages: false

  ## Callbacks

  @impl :gen_event
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

  @impl :gen_event
  def handle_call({:configure, options}, state) do
    config =
      Application.get_env(:logger, __MODULE__, [])
      |> Keyword.merge(options)

    Application.put_env(:logger, __MODULE__, config)
    {:ok, :ok, struct(state, config)}
  end

  @impl :gen_event
  def handle_event({level, _gl, {Logger, msg, _ts, meta}}, state) do
    level = maybe_ensure_warning_level(level)

    if Logger.compare_levels(level, state.level) != :lt and
         not LoggerUtils.excluded_domain?(meta[:domain], state.excluded_domains) do
      log(level, msg, meta, state)
    end

    {:ok, state}
  end

  def handle_event(_, state) do
    {:ok, state}
  end

  @impl :gen_event
  def handle_info(_, state) do
    {:ok, state}
  end

  @impl :gen_event
  def code_change(_old_vsn, state, _extra) do
    {:ok, state}
  end

  @impl :gen_event
  def terminate(_reason, _state) do
    :ok
  end

  ## Helpers

  defp log(level, msg, meta, state) do
    opts = LoggerUtils.build_sentry_options(level, meta, state.metadata)

    case meta[:crash_reason] do
      # If the crash reason is an exception, we want to report the exception itself
      # for better event reporting.
      {exception, stacktrace} when is_exception(exception) and is_list(stacktrace) ->
        Sentry.capture_exception(exception, Keyword.put(opts, :stacktrace, stacktrace))

      # If the crash reason is a {reason, stacktrace} tuple, then we can report
      # the originally-logged message (as a message) and include the stacktrace in
      # the event plus the original crash reason in the extra data.
      {other, stacktrace} when is_list(stacktrace) ->
        opts =
          opts
          |> Keyword.put(:stacktrace, stacktrace)
          |> Keyword.update!(:extra, &Map.put(&1, :crash_reason, inspect(other)))

        case msg_to_binary(msg) do
          {:ok, msg} -> Sentry.capture_message(msg, opts)
          :error -> :ok
        end

      _ ->
        if state.capture_log_messages do
          case msg_to_binary(msg) do
            {:ok, msg} -> Sentry.capture_message(msg, opts)
            :error -> :ok
          end
        end
    end
  end

  defp msg_to_binary(msg) when is_binary(msg), do: {:ok, msg}

  defp msg_to_binary(msg) do
    {:ok, :unicode.characters_to_binary(msg)}
  rescue
    _ -> :error
  end

  defp maybe_ensure_warning_level(:warn), do: :warning
  defp maybe_ensure_warning_level(level), do: level
end
