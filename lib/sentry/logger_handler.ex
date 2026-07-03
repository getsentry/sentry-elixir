defmodule Sentry.LoggerHandler do
  rate_limiting_options_schema = [
    max_events: [
      type: :non_neg_integer,
      required: true,
      doc: "The maximum number of events to send to Sentry in the `:interval` period."
    ],
    interval: [
      type: :non_neg_integer,
      required: true,
      doc: "The interval (in *milliseconds*) to send `:max_events` events."
    ]
  ]

  options_schema = [
    level: [
      type:
        {:in,
         [:emergency, :alert, :critical, :error, :warning, :warn, :notice, :info, :debug, nil]},
      default: :error,
      type_doc: "`t:Logger.level/0`",
      doc: """
      The minimum [`Logger`
      level](https://hexdocs.pm/logger/Logger.html#module-levels) to send events for.
      """
    ],
    excluded_domains: [
      type: {:list, :atom},
      default: [:cowboy],
      type_doc: "list of `t:atom/0`",
      doc: """
      Any messages with a domain in the configured list will not be sent. The default is so as
      to avoid double-reporting events from `Sentry.PlugCapture`.
      """
    ],
    metadata: [
      type: {:or, [{:list, :atom}, {:in, [:all]}]},
      default: [],
      type_doc: "list of `t:atom/0`, or `:all`",
      doc: """
      Use this to include non-Sentry logger metadata in reports. If it's a list of keys, metadata
      in those keys will be added in the `:extra` context (see
      `Sentry.Context.set_extra_context/1`) under the `:logger_metadata` key.
      If set to `:all`, all metadata will be included.
      """
    ],
    tags_from_metadata: [
      type: {:list, :atom},
      default: [],
      doc: """
      Use this to include logger metadata as tags in reports. Metadata under the specified keys
      in those keys will be added as tags to the event. *Available since v10.9.0*.
      """
    ],
    capture_log_messages: [
      type: :boolean,
      default: false,
      doc: """
      When `true`, this module will report all logged messages to Sentry (provided they're not
      filtered by `:excluded_domains` and `:level`). The default of `false` means that the
      handler will only send **crash reports**, which are messages with metadata that has the
      shape of an exit reason and a stacktrace.
      """
    ],
    rate_limiting: [
      type: {:or, [{:in, [nil]}, {:non_empty_keyword_list, rate_limiting_options_schema}]},
      doc: """
      *since v10.4.0* - If present, enables rate
      limiting of reported messages. This can help avoid "spamming" Sentry with
      repeated log messages. To disable rate limiting, set this to `nil` or don't
      pass it altogether.

      #{NimbleOptions.docs(rate_limiting_options_schema)}
      """,
      type_doc: "`t:keyword/0` or `nil`",
      default: nil
    ],
    sync_threshold: [
      type: {:or, [nil, :non_neg_integer]},
      default: 100,
      doc: """
      (*since v10.6.0*) The number of queued events after which this handler switches
      to *sync mode*. Generally, this handler sends messages to Sentry **asynchronously**,
      equivalent to using `result: :none` in `Sentry.send_event/2`. However, if the number
      of queued events exceeds this threshold, the handler will switch to *sync mode*,
      where it starts using `result: :sync` to block until the event is sent. If you always
      want to use sync mode, set this option to `0`. This option effectively implements
      **overload protection**.

      If you would rather *drop events* to shed load instead, use the `:discard_threshold` option.
      `:sync_threshold` and `:discard_threshold` cannot be used together. The default behavior
      of the handler is to switch to sync mode, so to disable this option and discard events
      instead set `:sync_threshold` to `nil` and set `:discard_threshold` instead.
      """
    ],
    discard_threshold: [
      type: {:or, [nil, :non_neg_integer]},
      default: nil,
      doc: """
      (*since v10.9.0*) The number of queued events after which this handler will start
      to **discard** events. This option effectively implements **load shedding**.

      `:discard_threshold` and `:sync_threshold` cannot be used together. If you set this option,
      set `:sync_threshold` to `nil`.
      """
    ],
    enable_logs: [
      type: {:or, [:boolean, nil]},
      default: nil,
      doc: false
    ]
  ]

  @options_schema NimbleOptions.new!(options_schema)

  @moduledoc """
  A highly-configurable [`:logger` handler](https://www.erlang.org/doc/apps/kernel/logger_chapter.html#handlers)
  that reports logged messages and crashes to Sentry.

  *This module is available since v9.0.0 of this library*.

  This handler can do **two distinct things** with the messages it receives:

    * **Error events** — report crashes and (optionally) `Logger` messages such as
      `Logger.error("oops")` to Sentry as **errors/messages**, the same way
      `Sentry.capture_exception/2` and `Sentry.capture_message/2` do. This is always
      active when the handler is attached.

    * **Structured logs** — forward log entries to [Sentry's Logs
      UI](https://develop.sentry.dev/sdk/telemetry/logs/) as structured log events. This
      is active when `:enable_logs` is `true` in your Sentry configuration.

  The two are independent: a single log can become an error event, a structured log, both,
  or neither, depending on configuration.

  > #### You usually don't add this handler manually {: .tip}
  >
  > Setting `config :sentry, enable_logs: true` makes the SDK **automatically attach**
  > this handler at startup — you do **not** need to call `:logger.add_handler/3` or
  > `Logger.add_handlers/1` yourself. Configure it through the `:logs` option of your
  > Sentry config (see the [Sentry configuration](Sentry.html#module-configuration) and the
  > ["Sending logs to Sentry"](#module-sending-logs-to-sentry) section below). Add the
  > handler manually only when you want full control over the options documented under
  > ["Configuration"](#module-configuration), or when you want error reporting **without**
  > structured logs.

  > #### When to Use the Handler vs the Backend? {: .info}
  >
  > Sentry's Elixir SDK also ships with `Sentry.LoggerBackend`, an Elixir `Logger`
  > backend. The backend has similar functionality to this handler. The main functional
  > difference is that `Sentry.LoggerBackend` runs in its own process, while
  > `Sentry.LoggerHandler` runs in the process that logs. The latter is generally
  > preferable.
  >
  > The reason both exist is that `:logger` handlers are a relatively-new
  > feature in Erlang/OTP, and `Sentry.LoggerBackend` was created before `:logger`
  > handlers were introduced.
  >
  > In general, use `Sentry.LoggerHandler` whenever possible. In future Elixir releases,
  > `Logger` backends may become deprecated and hence `Sentry.LoggerBackend` may be
  > eventually removed.

  ## Features

  This logger handler provides the features listed here.

  ### Crash Reports

  The reason you'll want to add this handler to your application is so that you can
  report **crashes** in your system to Sentry. Sometimes, you're able to catch exceptions
  and handle them (such as reporting them to Sentry), which is what you can do with
  `Sentry.PlugCapture` for example.

  However, Erlang/OTP systems are made of processes running concurrently, and
  sometimes those processes **crash and exit**. If you're not explicitly catching
  exceptions in those processes to report them to Sentry, then you won't see those
  crash reports in Sentry. That's where this handler comes in. This handler hooks
  into `:logger` and reports nicely-formatted crash reports to Sentry.

  ### Overload Protection

  This handler has built-in *overload protection* via the `:sync_threshold`
  configuration option. Under normal circumstances, this handler sends events to
  Sentry asynchronously, without blocking the logging process. However, if the
  number of queued up events exceeds the `:sync_threshold`, then this handler
  starts *blocking* the logging process until the event is sent.

  *Overload protection is available since v10.6.0*.

  ### Rate Limiting

  You can configure this handler to rate-limit the number of messages it sends to
  Sentry. This can help avoid "spamming" Sentry. See the `:rate_limiting` configuration
  option.

  *Rate limiting is available since v10.5.0*.

  ## Usage

  To add this handler to your system, see [the documentation for handlers in
  Elixir](https://hexdocs.pm/logger/Logger.html#module-erlang-otp-handlers).

  You can configure this handler in the `:logger` key under your application's configuration,
  potentially alongside other `:logger` handlers:

      config :my_app, :logger, [
        {:handler, :my_sentry_handler, Sentry.LoggerHandler, %{
          config: %{metadata: [:file, :line]}
        }}
      ]

  If you do this, then you'll want to add this to your application's `c:Application.start/2`
  callback, similarly to what you would do with `Sentry.LoggerBackend` and the
  call to `Logger.add_backend/1`:

      def start(_type, _args) do
        Logger.add_handlers(:my_app)

        # ...
      end

  Alternatively, you can *skip the `:logger` configuration* and add the handler directly
  to your application's `c:Application.start/2` callback:

      def start(_type, _args) do
        :logger.add_handler(:my_sentry_handler, Sentry.LoggerHandler, %{
          config: %{metadata: [:file, :line]}
        })

        # ...
      end

  ## Sending logs to Sentry

  To send structured logs to [Sentry's Logs UI](https://develop.sentry.dev/sdk/telemetry/logs/),
  enable logs in your Sentry configuration. This auto-attaches the handler — there is
  **no need** to configure `:logger` or call `:logger.add_handler/3`:

      config :sentry,
        # ...
        enable_logs: true,
        logs: [level: :info, metadata: [:request_id]]

  With this configuration, every `Logger` call at `:info` or above becomes a structured log
  event in Sentry, and crashes are still reported as **error events** (just like the manual
  setup above). The `:logs` options are documented in the
  [Sentry configuration](Sentry.html#module-configuration).

  ### Also capturing `Logger` messages as error events

  By default the auto-attached handler reports **crashes** as error events but leaves
  standalone messages (such as `Logger.error("oops")`) as structured logs only. To also
  report those messages as error events — for example, to turn `Logger.error/1` calls into
  Sentry issues while keeping `Logger.info/1` out of your issues stream — use the `:capture_*`
  keys under `:logs`:

      config :sentry,
        enable_logs: true,
        logs: [
          level: :info,                          # structured logs at :info and above -> Logs UI
          capture_log_messages: true,            # also report messages as error events...
          capture_level: :error,                 # ...but only at :error and above
          capture_metadata: :all,                # include Logger metadata in those error events
          capture_excluded_domains: [:cowboy]    # domains to exclude from those error events
        ]

  The `:capture_*` keys configure the **error-event** side and are independent from the
  matching Logs-UI keys (`:metadata`/`:capture_metadata`,
  `:excluded_domains`/`:capture_excluded_domains`).

  > #### Including `Logger` metadata {: .info}
  >
  > For the auto-attached handler, metadata for the two destinations is configured
  > separately. The `:metadata` key **under `:logs`** lists the `Logger` metadata attached
  > as attributes on **structured logs** (shown in the Logs UI). The `:capture_metadata`
  > key lists the metadata attached under `:extra` (as `logger_metadata`) on **error
  > events**. Both accept a list of keys or `:all`, and both default to `[]`. So if your
  > custom metadata is missing from a captured *error event*, set
  > `config :sentry, logs: [capture_metadata: [...]]` (or `:all`). When you add the handler
  > manually instead, use this module's own `:metadata`
  > [configuration option](#module-configuration).

  ## Configuration

  This handler supports the following configuration options:

  #{NimbleOptions.docs(@options_schema)}

  ## Examples

  To log all messages with level `:error` and above to Sentry, set `:capture_log_messages`
  to `true`:

      config :my_app, :logger, [
        {:handler, :my_sentry_handler, Sentry.LoggerHandler, %{
          config: %{metadata: [:file, :line], capture_log_messages: true, level: :error}
        }}
      ]

  Now, logs like this will be reported as messages to Sentry:

      Logger.error("Something went wrong")

  If you want to customize options for the reported message, use the `:sentry` metadata
  key in the `Logger` call. For example, to add a tag to the Sentry event:

      Logger.error("Something went wrong", sentry: [tags: %{my_tag: "my_value"}])

  Sentry context (in `:sentry`) is also read from the logger metadata, so you can configure
  it for a whole process (with `Logger.metadata/1`). Last but not least, context is also read
  from the ancestor chain of the process (`:"$callers"`), so if you set `:sentry` context
  in a process and then spawn something like a task or a GenServer from that process,
  the context will be included in the reported messages.
  """

  @moduledoc since: "9.0.0"

  alias Sentry.Config
  alias Sentry.LoggerHandler.{ErrorBackend, LogsBackend, RateLimiter}

  # The config for this logger handler.
  #
  # The `:level`, `:excluded_domains`, `:metadata`, and other fields above `:backends`
  # configure the error-event side (ErrorBackend). The `:logs_*` fields hold the
  # structured-logs side (LogsBackend) settings, read from the global `:logs`
  # configuration when the handler is set up.
  defstruct [
    :level,
    :excluded_domains,
    :metadata,
    :tags_from_metadata,
    :capture_log_messages,
    :rate_limiting,
    :sync_threshold,
    :discard_threshold,
    :enable_logs,
    :logs_level,
    :logs_excluded_domains,
    :logs_metadata,
    backends: []
  ]

  ## Logger handler callbacks

  # Callback for :logger handlers
  @doc false
  @spec adding_handler(:logger.handler_config()) :: {:ok, :logger.handler_config()}
  def adding_handler(config) do
    # The :config key may not be here.
    sentry_config = Map.get(config, :config, %{})

    handler_config = cast_config(%__MODULE__{}, sentry_config)

    # When :enable_logs is set on the handler config, it takes precedence over
    # the global Config.enable_logs?() — which may not resolve correctly in the
    # logger-server process during async tests.
    enable_logs? =
      case handler_config.enable_logs do
        nil -> Config.enable_logs?()
        bool -> bool
      end

    backends = [ErrorBackend] ++ if enable_logs?, do: [LogsBackend], else: []
    handler_config = %{handler_config | backends: backends}

    handler_config = prepare_logs_config(handler_config)

    config = Map.put(config, :config, handler_config)

    result =
      if rate_limiting_config = config.config.rate_limiting do
        _ = RateLimiter.start_under_sentry_supervisor(config.id, rate_limiting_config)
        {:ok, config}
      else
        {:ok, config}
      end

    # If a user explicitly registers their own Sentry.LoggerHandler (i.e., not the
    # auto-registered :sentry_log_handler), remove the auto-registered one to prevent
    # duplicate log capture. We do this after all validation so that if config is
    # invalid (and adding_handler raises), the auto-handler stays active. We spawn a
    # separate process because adding_handler/1 is called from within the logger
    # gen_server process, and calling :logger.remove_handler/1 directly would deadlock.
    if config.id != :sentry_log_handler do
      _ = spawn(fn -> :logger.remove_handler(:sentry_log_handler) end)
      :ok
    end

    result
  end

  # Callback for :logger handlers
  @doc false
  @spec changing_config(:update, :logger.handler_config(), :logger.handler_config()) ::
          {:ok, :logger.handler_config()}
  def changing_config(:update, old_config, new_config) do
    new_sentry_config =
      if is_struct(new_config.config, __MODULE__) do
        # Drop the internally-managed fields that are not part of the user-facing
        # options schema so they don't trip NimbleOptions validation: :backends is
        # carried over from the existing config, and the :logs_* settings are
        # re-derived from the current global config by prepare_logs_config/1 below.
        new_config.config
        |> Map.from_struct()
        |> Map.drop([:backends, :logs_level, :logs_excluded_domains, :logs_metadata])
      else
        new_config.config
      end

    # Re-read the structured-logs settings whenever the handler is reconfigured, so
    # updating (or re-adding via the application's auto-attach path) refreshes the
    # :logs_* values instead of leaving stale ones.
    updated_config =
      old_config
      |> update_in([:config], &cast_config(&1, new_sentry_config))
      |> update_in([:config], &prepare_logs_config/1)

    _ignored =
      cond do
        updated_config.config.rate_limiting == old_config.config.rate_limiting ->
          :ok

        # Turn off rate limiting.
        old_config.config.rate_limiting && is_nil(updated_config.config.rate_limiting) ->
          :ok = RateLimiter.terminate_and_delete(updated_config.id)

        # Turn on rate limiting.
        is_nil(old_config.config.rate_limiting) && updated_config.config.rate_limiting ->
          RateLimiter.start_under_sentry_supervisor(
            updated_config.id,
            updated_config.config.rate_limiting
          )

        # The config changed, so restart the rate limiter with the new config.
        true ->
          :ok = RateLimiter.terminate_and_delete(updated_config.id)

          RateLimiter.start_under_sentry_supervisor(
            updated_config.id,
            updated_config.config.rate_limiting
          )
      end

    {:ok, updated_config}
  end

  # Callback for :logger handlers
  @doc false
  def removing_handler(%{id: id}) do
    :ok = RateLimiter.terminate_and_delete(id)
  end

  # Callback for :logger handlers
  @doc false
  @spec log(:logger.log_event(), :logger.handler_config()) :: :ok
  def log(log_event, %{config: %__MODULE__{backends: backends} = config, id: handler_id}) do
    # Dispatch to all configured backends.
    # Rescue any exceptions to prevent OTP from removing the handler entirely
    # when a single event fails to process.
    Enum.each(backends, fn backend ->
      try do
        backend.handle_event(log_event, config, handler_id)
      rescue
        _ -> :ok
      end
    end)

    :ok
  end

  ## Helpers

  # Reads the structured-logs settings (level, excluded domains, metadata) from the
  # global :logs configuration into the handler config. Only done when LogsBackend is
  # active for the handler; otherwise the :logs_* fields stay nil since they would never
  # be read.
  defp prepare_logs_config(%__MODULE__{backends: backends} = config) do
    if LogsBackend in backends do
      %{
        config
        | logs_level: Config.logs_level(),
          logs_excluded_domains: Config.logs_excluded_domains(),
          logs_metadata: Config.logs_metadata()
      }
    else
      config
    end
  end

  defp cast_config(%__MODULE__{} = existing_config, %{} = new_config) do
    validated_config =
      new_config
      |> Map.to_list()
      |> NimbleOptions.validate!(@options_schema)

    config = struct!(existing_config, validated_config)

    if config.sync_threshold && config.discard_threshold do
      raise ArgumentError,
            ":sync_threshold and :discard_threshold cannot be used together, one of them must be nil"
    else
      config
    end
  end
end
