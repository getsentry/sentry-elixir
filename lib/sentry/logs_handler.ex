defmodule Sentry.LogsHandler do
  @moduledoc """
  A [`:logger` handler](https://www.erlang.org/doc/apps/kernel/logger_chapter.html#handlers)
  that sends log events to Sentry as structured logs.

  *This module is available since v11.0.0 of this library*.

  This handler is **different** from `Sentry.LoggerHandler`. While `Sentry.LoggerHandler`
  sends logged messages as regular Sentry events (errors/messages), this handler sends
  them as structured log events following the
  [Sentry Logs Protocol](https://develop.sentry.dev/sdk/telemetry/logs/).

  ## When to Use This Handler

  Use `Sentry.LogsHandler` when you want to:

  - Send application logs to Sentry as structured telemetry data
  - Maintain high-volume logging without overwhelming Sentry's error tracking
  - Correlate logs with traces and spans in distributed tracing scenarios
  - Take advantage of Sentry's log aggregation and search capabilities

  ## Configuration

  This handler **requires** that you set `enable_logs: true` in your Sentry configuration.
  If this is not set, the handler will not send any log events.

      # In config/config.exs
      config :sentry,
        dsn: "https://public:secret@app.getsentry.com/1",
        enable_logs: true

  ## Usage

  To add this handler to your system, see [the documentation for handlers in
  Elixir](https://hexdocs.pm/logger/Logger.html#module-erlang-otp-handlers).

  You can configure this handler in the `:logger` key under your application's configuration:

      config :my_app, :logger, [
        {:handler, :sentry_logs_handler, Sentry.LogsHandler, %{
          config: %{level: :info}
        }}
      ]

  Then add this to your application's `c:Application.start/2` callback:

      def start(_type, _args) do
        Logger.add_handlers(:my_app)
        # ...
      end

  Alternatively, you can add the handler directly in your application's `c:Application.start/2`:

      def start(_type, _args) do
        :logger.add_handler(:sentry_logs_handler, Sentry.LogsHandler, %{
          config: %{level: :info}
        })
        # ...
      end

  ## Configuration Options

  This handler supports the following configuration options:

    * `:level` - The minimum log level to send to Sentry. Defaults to `:info`.
      Valid values are: `:emergency`, `:alert`, `:critical`, `:error`, `:warning`,
      `:warn`, `:notice`, `:info`, `:debug`.

    * `:excluded_domains` - A list of logger domains to exclude. Messages with
      a domain in this list will not be sent to Sentry. Defaults to `[]`.

    * `:metadata` - Logger metadata keys to include as attributes in the log event.
      Can be a list of atoms or `:all` to include all metadata. Defaults to `[]`.

  ## Examples

      # Send all info-level and above logs to Sentry
      :logger.add_handler(:sentry_logs_handler, Sentry.LogsHandler, %{
        config: %{level: :info}
      })

      # Send error logs with all metadata
      :logger.add_handler(:sentry_logs_handler, Sentry.LogsHandler, %{
        config: %{
          level: :error,
          metadata: :all
        }
      })

      # Exclude certain domains
      :logger.add_handler(:sentry_logs_handler, Sentry.LogsHandler, %{
        config: %{
          level: :info,
          excluded_domains: [:cowboy, :ranch]
        }
      })
  """

  @moduledoc since: "12.0.0"

  require Logger
  alias Sentry.{Config, LogEvent, LogEventBuffer, LoggerUtils}

  # Configuration schema
  options_schema = [
    level: [
      type:
        {:in,
         [:emergency, :alert, :critical, :error, :warning, :warn, :notice, :info, :debug, nil]},
      default: :info,
      type_doc: "`t:Logger.level/0`",
      doc: "The minimum Logger level to send log events for."
    ],
    excluded_domains: [
      type: {:list, :atom},
      default: [],
      type_doc: "list of `t:atom/0`",
      doc: """
      Any messages with a domain in the configured list will not be sent.
      """
    ],
    metadata: [
      type: {:or, [{:list, :atom}, {:in, [:all]}]},
      default: [],
      type_doc: "list of `t:atom/0`, or `:all`",
      doc: """
      Logger metadata keys to include as attributes in the log event.
      If set to `:all`, all metadata will be included.
      """
    ],
    buffer: [
      type: {:or, [:atom, :pid, {:tuple, [:atom, :atom]}]},
      default: LogEventBuffer,
      type_doc: "`t:GenServer.server/0`",
      doc: false
    ]
  ]

  @options_schema NimbleOptions.new!(options_schema)

  # The config for this logger handler
  defstruct [
    :level,
    :excluded_domains,
    :metadata,
    :buffer
  ]

  ## Logger handler callbacks

  @doc false
  @spec adding_handler(:logger.handler_config()) :: {:ok, :logger.handler_config()}
  def adding_handler(config) do
    # Check if logs are enabled
    unless Config.enable_logs?() do
      Logger.warning(
        "Sentry.LogsHandler is being added but enable_logs is set to false. " <>
          "No log events will be sent to Sentry. Set enable_logs: true in your Sentry configuration."
      )
    end

    # The :config key may not be here.
    sentry_config = Map.get(config, :config, %{})

    config = Map.put(config, :config, cast_config(%__MODULE__{}, sentry_config))

    {:ok, config}
  end

  @doc false
  @spec changing_config(:update, :logger.handler_config(), :logger.handler_config()) ::
          {:ok, :logger.handler_config()}
  def changing_config(:update, old_config, new_config) do
    new_sentry_config =
      if is_struct(new_config.config, __MODULE__) do
        Map.from_struct(new_config.config)
      else
        new_config.config
      end

    updated_config = update_in(old_config.config, &cast_config(&1, new_sentry_config))

    {:ok, updated_config}
  end

  @doc false
  def removing_handler(_config) do
    :ok
  end

  @doc false
  @spec log(:logger.log_event(), :logger.handler_config()) :: :ok
  def log(%{level: log_level, meta: log_meta} = log_event, %{
        config: %__MODULE__{} = config
      }) do
    cond do
      # Check if logs are enabled globally
      not Config.enable_logs?() ->
        :ok

      # Check log level
      Logger.compare_levels(log_level, config.level) == :lt ->
        :ok

      # Check excluded domains
      LoggerUtils.excluded_domain?(Map.get(log_meta, :domain, []), config.excluded_domains) ->
        :ok

      true ->
        # Extract metadata as attributes
        attributes = extract_metadata(log_meta, config.metadata)

        # Extract parameters for message template interpolation (if provided via metadata)
        parameters = Map.get(log_meta, :parameters)

        # Create log event
        log_event_struct = LogEvent.from_logger_event(log_event, attributes, parameters)

        # Add to buffer
        LogEventBuffer.add_event(log_event_struct, server: config.buffer)

        :ok
    end
  end

  ## Private helpers

  defp cast_config(%__MODULE__{} = existing_config, %{} = new_config) do
    validated_config =
      new_config
      |> Map.to_list()
      |> NimbleOptions.validate!(@options_schema)

    struct!(existing_config, validated_config)
  end

  defp extract_metadata(_log_meta, []), do: %{}

  defp extract_metadata(log_meta, :all) do
    # Include all metadata except Sentry-internal keys
    log_meta
    |> Map.drop([:time, :gl, :report_cb, :domain, :mfa, :file, :line, :pid])
    |> Enum.into(%{})
  end

  defp extract_metadata(log_meta, metadata_keys) when is_list(metadata_keys) do
    Enum.reduce(metadata_keys, %{}, fn key, acc ->
      case Map.fetch(log_meta, key) do
        {:ok, value} -> Map.put(acc, key, value)
        :error -> acc
      end
    end)
  end
end
