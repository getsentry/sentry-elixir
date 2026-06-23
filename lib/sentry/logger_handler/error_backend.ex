defmodule Sentry.LoggerHandler.ErrorBackend do
  @moduledoc false

  # Backend that captures errors/crashes and sends them to Sentry's error API.
  #
  # This is the original LoggerHandler behavior, extracted into a backend module.
  # It handles crash reports, GenServer errors, Ranch errors, and optionally
  # all log messages when capture_log_messages is enabled.

  @behaviour Sentry.LoggerHandler.Backend

  alias Sentry.LoggerHandler.RateLimiter
  alias Sentry.LoggerUtils
  alias Sentry.Transport.SenderPool

  @impl true
  def handle_event(%{level: log_level, meta: log_meta} = log_event, config, handler_id) do
    cond do
      Logger.compare_levels(log_level, config.level) == :lt ->
        :ok

      LoggerUtils.excluded_domain?(Map.get(log_meta, :domain, []), config.excluded_domains) ->
        :ok

      config.rate_limiting && RateLimiter.increment(handler_id) == :rate_limited ->
        :ok

      # Discard event.
      config.discard_threshold &&
          SenderPool.get_queued_events_counter() >= config.discard_threshold ->
        :ok

      true ->
        # Logger handlers run in the process that logs, so we already read all the
        # necessary Sentry context from the process dictionary (when creating the event).
        sentry_opts =
          LoggerUtils.build_sentry_options(
            log_level,
            log_meta[:sentry],
            log_meta,
            config.metadata,
            config.tags_from_metadata
          )

        log_unfiltered(log_event, sentry_opts, config)
    end
  end

  # Elixir 1.19 puts string translation inside the report instead of replacing
  # it completely. We switch it back for compatibility with existing code.
  defp log_unfiltered(
         %{msg: {:report, %{elixir_translation: unicode_chardata}}} = log_event,
         sentry_opts,
         config
       ) do
    log_unfiltered(%{log_event | msg: {:string, unicode_chardata}}, sentry_opts, config)
  end

  # A string was logged. We check for the :crash_reason metadata and try to build a sensible
  # report from there, otherwise we use the logged string directly.
  defp log_unfiltered(
         %{msg: {:string, unicode_chardata}} = log_event,
         sentry_opts,
         config
       ) do
    log_from_crash_reason(log_event.meta[:crash_reason], unicode_chardata, sentry_opts, config)
  end

  # "report" here is of type logger:report/0, which is a struct, map or keyword list.
  defp log_unfiltered(%{msg: {:report, report}}, sentry_opts, config)
       when is_struct(report) do
    capture(:message, inspect(report), sentry_opts, config)
  end

  defp log_unfiltered(%{msg: {:report, report}}, sentry_opts, config) do
    case Map.new(report) do
      %{reason: {exception, stacktrace}}
      when is_exception(exception) and is_list(stacktrace) ->
        sentry_opts = Keyword.merge(sentry_opts, stacktrace: stacktrace, handled: false)
        capture(:exception, exception, sentry_opts, config)

      %{reason: {reason, stacktrace}} when is_list(stacktrace) ->
        sentry_opts = Keyword.put(sentry_opts, :stacktrace, stacktrace)
        capture(:message, "** (stop) " <> Exception.format_exit(reason), sentry_opts, config)

      %{reason: reason} ->
        sentry_opts =
          Keyword.update!(sentry_opts, :extra, &Map.put(&1, :crash_reason, inspect(reason)))

        capture(:message, "** (stop) #{Exception.format_exit(reason)}", sentry_opts, config)

      # Special-case Ranch messages because their formatting is their formatting.
      %{format: ~c"Ranch listener ~p" ++ _, args: args} ->
        capture_from_ranch_error(args, sentry_opts, config)

      # Handles errors which may occur on < 1.15 when there are crashes during
      # initialization of some processes.
      %{label: {_lib, _reason}, report: report} when is_list(report) ->
        error = Enum.find(report, fn {name, _value} -> name == :error_info end)
        {_, exception, stacktrace} = error

        sentry_opts = Keyword.merge(sentry_opts, stacktrace: stacktrace, handled: false)

        capture(:exception, exception, sentry_opts, config)

      _ ->
        if config.capture_log_messages do
          capture(:message, inspect(report), sentry_opts, config)
        else
          :ok
        end
    end
  end

  defp log_unfiltered(
         %{msg: {format, format_args}} = log_event,
         sentry_opts,
         config
       ) do
    string_message = format |> :io_lib.format(format_args) |> IO.chardata_to_string()
    log_from_crash_reason(log_event.meta[:crash_reason], string_message, sentry_opts, config)
  end

  defp log_from_crash_reason(
         {exception, stacktrace},
         _chardata_message,
         sentry_opts,
         config
       )
       when is_exception(exception) and is_list(stacktrace) do
    sentry_opts = Keyword.merge(sentry_opts, stacktrace: stacktrace, handled: false)
    capture(:exception, exception, sentry_opts, config)
  end

  defp log_from_crash_reason(
         {reason, stacktrace},
         chardata_message,
         sentry_opts,
         config
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
         %{capture_log_messages: true} = config
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

  # Sometimes there's an extra sneaky [] in there.
  defp extra_info_from_message([
         [
           "GenServer ",
           _pid,
           " terminating",
           _reason,
           [],
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
             _whatever_this_is = [],
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

  # This is only causing issues on OTP 25 apparently.
  # TODO: remove special-cased Ranch handling when we depend on OTP 26+.
  #
  # The reason is always the *last* element of the Ranch args list, but the list's
  # arity varies across ranch/cowboy versions (4-element for :cowboy_clear crashes,
  # 5-element for others), so we pull it positionally rather than matching a fixed
  # arity. The reason itself shows up in a few shapes, and we want to preserve the
  # stacktrace whenever one is present:
  #
  #   * {{exception, stacktrace}, _} or {exception, stacktrace} -> structured exception.
  #   * {reason, stacktrace} where reason is not an exception (like {:badmatch, _},
  #     {:case_clause, _}, atoms) -> message event that still carries the stacktrace,
  #     reusing the same path as log_from_crash_reason/4.
  #   * anything else -> plain message with inspect(args).
  defp capture_from_ranch_error(args, sentry_opts, config) when is_list(args) do
    case normalize_ranch_reason(List.last(args)) do
      {:exception, exception, stacktrace, extra} ->
        sentry_opts = Keyword.merge(sentry_opts, stacktrace: stacktrace, handled: false)

        sentry_opts =
          if extra do
            add_extra_to_sentry_opts(sentry_opts, %{
              ranch_extra: inspect(extra, printable_limit: 4096, limit: 100)
            })
          else
            sentry_opts
          end

        capture(:exception, exception, sentry_opts, config)

      {:reason, reason, stacktrace} ->
        message = "Ranch listener error: #{inspect(args)}"
        log_from_crash_reason({reason, stacktrace}, message, sentry_opts, config)

      :error ->
        capture(:message, "Ranch listener error: #{inspect(args)}", sentry_opts, config)
    end
  end

  defp capture_from_ranch_error(args, sentry_opts, config) do
    capture(:message, "Ranch listener error: #{inspect(args)}", sentry_opts, config)
  end

  # Doubly-nested {{exception, stacktrace}, extra} (the original matched shape). The
  # trailing "extra" is Cowboy's context about what it was doing (often an MFA or
  # partial request/stream state), so we preserve it under the event's extra metadata.
  defp normalize_ranch_reason({{exception, stacktrace}, extra})
       when is_exception(exception) and is_list(stacktrace) do
    {:exception, exception, stacktrace, extra}
  end

  # Bare {exception, stacktrace}, with no trailing Cowboy context.
  defp normalize_ranch_reason({exception, stacktrace})
       when is_exception(exception) and is_list(stacktrace) do
    {:exception, exception, stacktrace, _extra = nil}
  end

  # Non-exception reason (throw/badmatch/exit term) that still carries a stacktrace.
  # The whole reason (including any trailing term) is captured as extra by
  # log_from_crash_reason/4, so there's nothing extra to thread through here.
  defp normalize_ranch_reason({reason, stacktrace}) when is_list(stacktrace) do
    {:reason, reason, stacktrace}
  end

  defp normalize_ranch_reason(_other) do
    :error
  end

  defp add_extra_to_sentry_opts(sentry_opts, new_extra) do
    Keyword.update(sentry_opts, :extra, %{}, &Map.merge(new_extra, &1))
  end

  defp capture(:exception, exception, sentry_opts, config) do
    sentry_opts = maybe_switch_to_sync(sentry_opts, config)
    Sentry.capture_exception(exception, sentry_opts)
  end

  defp capture(:message, message, sentry_opts, config) do
    sentry_opts = maybe_switch_to_sync(sentry_opts, config)
    Sentry.capture_message(message, sentry_opts)
  end

  defp maybe_switch_to_sync(sentry_opts, config) do
    if config.sync_threshold &&
         SenderPool.get_queued_events_counter() >= config.sync_threshold do
      Keyword.put(sentry_opts, :result, :sync)
    else
      sentry_opts
    end
  end
end
