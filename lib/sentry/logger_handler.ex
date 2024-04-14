defmodule Sentry.LoggerHandler do
  @moduledoc """
  `:logger` handler to report logged events to Sentry.

  This module is similar to `Sentry.LoggerBackend`, but it implements a
  [`:logger` handler](https://erlang.org/doc/man/logger_chapter.html#handlers) rather
  than an Elixir's `Logger` backend. It provides additional functionality compared to
  the `Logger` backend, such as rate-limiting of reported messages, better fingerprinting,
  and better handling of crashes.

  *This module is available since v9.0.0 of this library*.

  > #### When to Use the Handler vs the Backend? {: .info}
  >
  > There is **no functional difference in behavior** between `Sentry.LoggerHandler` and
  > `Sentry.LoggerBackend` when it comes to reporting to Sentry. The main functional
  > difference is that `Sentry.LoggerBackend` runs in its own process, while
  > `Sentry.LoggerHandler` runs in the process that logs. The latter is generally
  > preferable.
  >
  > The reason both exist is that `:logger` handlers are a relatively-new
  > feature in Erlang/OTP, and `Sentry.LoggerBackend` was created before `:logger`
  > handlers were introduced.
  >
  > In general, try to use `Sentry.LoggerHandler` if possible. In future Elixir releases,
  > `Logger` backends may become deprecated and hence `Sentry.LoggerBackend` may be
  > eventually removed.

  ## Crash Reports

  The reason you'll want to add this handler to your application is so that you can
  report **crashes** in your system to Sentry. Sometimes, you're able to catch exceptions
  and handle them (such as reporting them to Sentry), which is what you can do with
  `Sentry.PlugCapture` for example.

  However, Erlang/OTP systems are made of processes running concurrently, and
  sometimes those processes **crash and exit**. If you're not explicitly catching
  exceptions in those processes to report them to Sentry, then you won't see those
  crash reports in Sentry. That's where this handler comes in. This handler hooks
  into `:logger` and reports nicely-formatted crash reports to Sentry.

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

    * `:excluded_domains` (list of `t:atom/0`) - any messages with a domain in
      the configured list will not be sent. Defaults to `[:cowboy]` to avoid
      double-reporting events from `Sentry.PlugCapture`.

    * `:metadata` (list of `t:atom/0`, or `:all`) - use this to include
      non-Sentry logger metadata in reports. If it's a list of keys, metadata in
      those keys will be added in the `:extra` context (see
      `Sentry.Context.set_extra_context/1`) under the `:logger_metadata` key.
      If set to `:all`, all metadata will be included. Defaults to `[]`.

    * `:level` (`t:Logger.level/0`) - the minimum [`Logger`
      level](https://hexdocs.pm/logger/Logger.html#module-levels) to send events for.
      Defaults to `:error`.

    * `:capture_log_messages` (`t:boolean/0`) - when `true`, this module will
      report all logged messages to Sentry (provided they're not filtered by
      `:excluded_domains` and `:level`). Defaults to `false`, which will only
      send **crash reports**, which are messages with metadata that has the
      shape of an exit reason and a stacktrace.

    * `:rate_limiting` (`t:keyword/0`, since *v10.4.0*) - if present, enables rate
      limiting of reported messages. This can help avoid "spamming" Sentry with
      repeated log messages. To disable rate limiting, set this to `nil` or don't
      pass it altogether (which is the default). If this option is present, these
      nested options are **required**:

      * `:max_events` (`t:non_neg_integer/0`) - the maximum number of events
        to send to Sentry in the `:interval` period.

      * `:interval` (`t:non_neg_integer/0`) - the interval (in *milliseconds*)
        to send `:max_events` events.

  """

  @moduledoc since: "9.0.0"

  alias Sentry.LoggerUtils
  alias Sentry.LoggerHandler.RateLimiter

  # The config for this logger handler.
  defstruct level: :error,
            excluded_domains: [:cowboy],
            metadata: [],
            capture_log_messages: false,
            rate_limiting: nil

  @valid_config_keys [
    :excluded_domains,
    :capture_log_messages,
    :metadata,
    :level,
    :rate_limiting
  ]

  ## Logger handler callbacks

  # Callback for :logger handlers
  @doc false
  @spec adding_handler(:logger.handler_config()) :: {:ok, :logger.handler_config()}
  def adding_handler(config) do
    config = Map.put_new(config, :config, %__MODULE__{})
    config = update_in(config.config, &cast_config(__MODULE__, &1))

    if rate_limiting_config = config.config.rate_limiting do
      _ = RateLimiter.start_under_sentry_supervisor(config.id, rate_limiting_config)
    end

    {:ok, config}
  end

  # Callback for :logger handlers
  @doc false
  @spec changing_config(:update, :logger.handler_config(), :logger.handler_config()) ::
          {:ok, :logger.handler_config()}
  def changing_config(:update, old_config, new_config) do
    _ignored =
      cond do
        new_config.config.rate_limiting == old_config.config.rate_limiting ->
          :ok

        # Turn off rate limiting.
        old_config.config.rate_limiting && is_nil(new_config.config.rate_limiting) ->
          :ok = RateLimiter.terminate_and_delete(new_config.id)

        # Turn on rate limiting.
        is_nil(old_config.config.rate_limiting) && new_config.config.rate_limiting ->
          RateLimiter.start_under_sentry_supervisor(
            new_config.id,
            new_config.config.rate_limiting
          )

        # The config changed, so restart the rate limiter with the new config.
        true ->
          :ok = RateLimiter.terminate_and_delete(new_config.id)

          RateLimiter.start_under_sentry_supervisor(
            new_config.id,
            new_config.config.rate_limiting
          )
      end

    {:ok, update_in(old_config.config, &cast_config(&1, new_config.config))}
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
  defp log_unfiltered(%{msg: {:report, report}}, sentry_opts, %__MODULE__{} = _config) do
    case Map.new(report) do
      %{report: %{reason: {exception, stacktrace}}}
      when is_exception(exception) and is_list(stacktrace) ->
        sentry_opts = Keyword.merge(sentry_opts, stacktrace: stacktrace, handled: false)
        Sentry.capture_exception(exception, sentry_opts)

      %{report: %{reason: {reason, stacktrace}}} when is_list(stacktrace) ->
        sentry_opts = Keyword.put(sentry_opts, :stacktrace, stacktrace)
        Sentry.capture_message("** (stop) " <> Exception.format_exit(reason), sentry_opts)

      %{report: report_info} ->
        Sentry.capture_message(inspect(report_info), sentry_opts)

      %{reason: {reason, stacktrace}} when is_list(stacktrace) ->
        sentry_opts = Keyword.put(sentry_opts, :stacktrace, stacktrace)
        Sentry.capture_message("** (stop) " <> Exception.format_exit(reason), sentry_opts)

      %{reason: reason} ->
        sentry_opts =
          Keyword.update!(sentry_opts, :extra, &Map.put(&1, :crash_reason, inspect(reason)))

        msg = "** (stop) #{Exception.format_exit(reason)}"
        Sentry.capture_message(msg, sentry_opts)

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

  defp cast_config(existing_config, new_config) do
    config_attrs = Map.take(new_config, @valid_config_keys)
    struct!(existing_config, config_attrs)
  end

  defp log_from_crash_reason(
         {exception, stacktrace},
         _chardata_message,
         sentry_opts,
         %__MODULE__{}
       )
       when is_exception(exception) and is_list(stacktrace) do
    sentry_opts = Keyword.merge(sentry_opts, stacktrace: stacktrace, handled: false)
    Sentry.capture_exception(exception, sentry_opts)
  end

  defp log_from_crash_reason({reason, stacktrace}, chardata_message, sentry_opts, %__MODULE__{})
       when is_list(stacktrace) do
    sentry_opts =
      sentry_opts
      |> Keyword.put(:stacktrace, stacktrace)
      |> Keyword.update!(:extra, &Map.put(&1, :crash_reason, inspect(reason)))
      |> Keyword.update!(:extra, &Map.merge(extra_info_from_message(chardata_message), &1))

    case reason do
      {type, {GenServer, :call, [_pid, call, _timeout]}} = reason
      when type in [:noproc, :timeout] ->
        sentry_opts =
          Keyword.put_new(sentry_opts, :fingerprint, [
            Atom.to_string(type),
            "genserver_call",
            inspect(call)
          ])

        Sentry.capture_message(Exception.format_exit(reason), sentry_opts)

      _other ->
        string_message = :unicode.characters_to_binary(chardata_message)
        Sentry.capture_message(string_message, sentry_opts)
    end
  end

  defp log_from_crash_reason(_other_reason, chardata_message, sentry_opts, %__MODULE__{
         capture_log_messages: true
       }) do
    string_message = :unicode.characters_to_binary(chardata_message)
    Sentry.capture_message(string_message, sentry_opts)
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
end
