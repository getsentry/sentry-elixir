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
      type: :non_neg_integer,
      default: 100,
      doc: """
      *since v10.6.0* - The number of queued events after which this handler switches
      to *sync mode*. Generally, this handler sends messages to Sentry **asynchronously**,
      equivalent to using `result: :none` in `Sentry.send_event/2`. However, if the number
      of queued events exceeds this threshold, the handler will switch to *sync mode*,
      where it starts using `result: :sync` to block until the event is sent. If you always
      want to use sync mode, set this option to `0`. This option effectively implements
      **overload protection**.
      """
    ]
  ]

  @options_schema NimbleOptions.new!(options_schema)

  @moduledoc """
  A highly-configurable [`:logger` handler](https://erlang.org/doc/man/logger_chapter.html#handlers)
  that reports logged messages and crashes to Sentry.

  *This module is available since v9.0.0 of this library*.

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
  Elixir](https://hexdocs.pm/logger/1.15.5/Logger.html#module-erlang-otp-handlers).

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

  alias Sentry.LoggerUtils
  alias Sentry.LoggerHandler.RateLimiter
  alias Sentry.Transport.SenderPool

  # The config for this logger handler.
  defstruct [
    :level,
    :excluded_domains,
    :metadata,
    :capture_log_messages,
    :rate_limiting,
    :sync_threshold
  ]

  ## Logger handler callbacks

  # Callback for :logger handlers
  @doc false
  @spec adding_handler(:logger.handler_config()) :: {:ok, :logger.handler_config()}
  def adding_handler(config) do
    # The :config key may not be here.
    sentry_config = Map.get(config, :config, %{})

    config = Map.put(config, :config, cast_config(%__MODULE__{}, sentry_config))

    if rate_limiting_config = config.config.rate_limiting do
      _ = RateLimiter.start_under_sentry_supervisor(config.id, rate_limiting_config)
      {:ok, config}
    else
      {:ok, config}
    end
  end

  # Callback for :logger handlers
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
  def log(%{level: log_level, meta: log_meta} = log_event, %{
        config: %__MODULE__{} = config,
        id: handler_id
      }) do
    cond do
      Logger.compare_levels(log_level, config.level) == :lt ->
        :ok

      LoggerUtils.excluded_domain?(Map.get(log_meta, :domain, []), config.excluded_domains) ->
        :ok

      config.rate_limiting && RateLimiter.increment(handler_id) == :rate_limited ->
        :ok

      true ->
        # Logger handlers run in the process that logs, so we already read all the
        # necessary Sentry context from the process dictionary (when creating the event).
        # If we take meta[:sentry] here, we would duplicate all the stuff. This
        # behavior is different than the one in Sentry.LoggerBackend because the Logger
        # backend runs in its own process.
        sentry_opts =
          LoggerUtils.build_sentry_options(
            log_level,
            log_meta[:sentry],
            log_meta,
            config.metadata
          )

        log_unfiltered(log_event, sentry_opts, config)
    end
  end

  # A string was logged. We check for the :crash_reason metadata and try to build a sensible
  # report from there, otherwise we use the logged string directly.
  defp log_unfiltered(
         %{msg: {:string, unicode_chardata}} = log_event,
         sentry_opts,
         %__MODULE__{} = config
       ) do
    log_from_crash_reason(log_event.meta[:crash_reason], unicode_chardata, sentry_opts, config)
  end

  # "report" here is of type logger:report/0, which is a map or keyword list.
  defp log_unfiltered(%{msg: {:report, report}}, sentry_opts, %__MODULE__{} = config) do
    case Map.new(report) do
      %{report: %{reason: {exception, stacktrace}}}
      when is_exception(exception) and is_list(stacktrace) ->
        sentry_opts = Keyword.merge(sentry_opts, stacktrace: stacktrace, handled: false)
        capture(:exception, exception, sentry_opts, config)

      %{report: %{reason: {reason, stacktrace}}} when is_list(stacktrace) ->
        sentry_opts = Keyword.put(sentry_opts, :stacktrace, stacktrace)
        capture(:message, "** (stop) " <> Exception.format_exit(reason), sentry_opts, config)

      %{report: report_info} ->
        capture(:message, inspect(report_info), sentry_opts, config)

      %{reason: {reason, stacktrace}} when is_list(stacktrace) ->
        sentry_opts = Keyword.put(sentry_opts, :stacktrace, stacktrace)
        capture(:message, "** (stop) " <> Exception.format_exit(reason), sentry_opts, config)

      %{reason: reason} ->
        sentry_opts =
          Keyword.update!(sentry_opts, :extra, &Map.put(&1, :crash_reason, inspect(reason)))

        capture(:message, "** (stop) #{Exception.format_exit(reason)}", sentry_opts, config)

      _other ->
        :ok
    end
  end

  defp log_unfiltered(
         %{msg: {format, format_args}} = log_event,
         sentry_opts,
         %__MODULE__{} = config
       ) do
    string_message = format |> :io_lib.format(format_args) |> IO.chardata_to_string()
    log_from_crash_reason(log_event.meta[:crash_reason], string_message, sentry_opts, config)
  end

  ## Helpers

  defp cast_config(%__MODULE__{} = existing_config, %{} = new_config) do
    validated_config =
      new_config
      |> Map.to_list()
      |> NimbleOptions.validate!(@options_schema)

    struct!(existing_config, validated_config)
  end

  defp log_from_crash_reason(
         {exception, stacktrace},
         _chardata_message,
         sentry_opts,
         %__MODULE__{} = config
       )
       when is_exception(exception) and is_list(stacktrace) do
    sentry_opts = Keyword.merge(sentry_opts, stacktrace: stacktrace, handled: false)
    capture(:exception, exception, sentry_opts, config)
  end

  defp log_from_crash_reason(
         {reason, stacktrace},
         chardata_message,
         sentry_opts,
         %__MODULE__{} = config
       )
       when is_list(stacktrace) do
    sentry_opts =
      sentry_opts
      |> Keyword.put(:stacktrace, stacktrace)
      |> add_extra_to_sentry_opts(%{crash_reason: inspect(reason)})
      |> add_extra_to_sentry_opts(extra_info_from_message(chardata_message))

    case reason do
      {type, {GenServer, :call, [_pid, call, _timeout]}} = reason
      when type in [:noproc, :timeout] ->
        sentry_opts =
          Keyword.put_new(sentry_opts, :fingerprint, [
            Atom.to_string(type),
            "genserver_call",
            inspect(call)
          ])

        capture(:message, Exception.format_exit(reason), sentry_opts, config)

      _other ->
        try_to_parse_message_or_just_report_it(chardata_message, sentry_opts, config)
    end
  end

  defp log_from_crash_reason(
         _other_reason,
         chardata_message,
         sentry_opts,
         %__MODULE__{
           capture_log_messages: true
         } = config
       ) do
    string_message = :unicode.characters_to_binary(chardata_message)
    capture(:message, string_message, sentry_opts, config)
  end

  defp log_from_crash_reason(_other_reason, _string_message, _sentry_opts, _config) do
    :ok
  end

  defp extra_info_from_message([
         [
           "GenServer ",
           _pid,
           " terminating",
           _reason,
           "\nLast message",
           _from,
           ": ",
           last_message
         ],
         "\nState: ",
         state | _rest
       ]) do
    %{genserver_state: state, last_message: last_message}
  end

  defp extra_info_from_message(_message) do
    %{}
  end

  # We do this because messages from Erlang's gen_* behaviours are often full of interesting
  # and useful data. For example, GenServer messages contain the PID, the reason, the last
  # message, and a treasure trove of stuff. If we cannot parse the message, such is life
  # and we just report it as is.

  defp try_to_parse_message_or_just_report_it(
         [
           [
             "GenServer ",
             inspected_pid,
             " terminating",
             chardata_reason,
             "\nLast message",
             [" (from ", inspected_sender_pid, ")"],
             ": ",
             inspected_last_message
           ],
           "\nState: ",
           inspected_state | _
         ],
         sentry_opts,
         config
       ) do
    string_reason = chardata_reason |> :unicode.characters_to_binary() |> String.trim()

    sentry_opts =
      sentry_opts
      |> Keyword.put(:interpolation_parameters, [inspected_pid])
      |> add_extra_to_sentry_opts(%{
        pid_which_sent_last_message: inspected_sender_pid,
        last_message: inspected_last_message,
        genserver_state: inspected_state
      })

    capture(:message, "GenServer %s terminating: #{string_reason}", sentry_opts, config)
  end

  defp try_to_parse_message_or_just_report_it(
         [
           [
             "GenServer ",
             inspected_pid,
             " terminating",
             chardata_reason,
             "\nLast message: ",
             inspected_last_message
           ],
           "\nState: ",
           inspected_state | _
         ],
         sentry_opts,
         config
       ) do
    string_reason = chardata_reason |> :unicode.characters_to_binary() |> String.trim()

    sentry_opts =
      sentry_opts
      |> Keyword.put(:interpolation_parameters, [inspected_pid])
      |> add_extra_to_sentry_opts(%{
        last_message: inspected_last_message,
        genserver_state: inspected_state
      })

    capture(:message, "GenServer %s terminating: #{string_reason}", sentry_opts, config)
  end

  defp try_to_parse_message_or_just_report_it(chardata_message, sentry_opts, config) do
    string_message = :unicode.characters_to_binary(chardata_message)
    capture(:message, string_message, sentry_opts, config)
  end

  defp add_extra_to_sentry_opts(sentry_opts, new_extra) do
    Keyword.update(sentry_opts, :extra, %{}, &Map.merge(new_extra, &1))
  end

  for function <- [:exception, :message] do
    sentry_fun = :"capture_#{function}"

    defp capture(unquote(function), exception_or_message, sentry_opts, %__MODULE__{} = config) do
      sentry_opts =
        if SenderPool.get_queued_events_counter() >= config.sync_threshold do
          Keyword.put(sentry_opts, :result, :sync)
        else
          sentry_opts
        end

      Sentry.unquote(sentry_fun)(exception_or_message, sentry_opts)
    end
  end
end
