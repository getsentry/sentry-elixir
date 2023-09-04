defmodule Sentry.LoggerHandler do
  @moduledoc """
  TODO
  """

  @moduledoc since: "9.0.0"

  alias Sentry.LoggerUtils

  defstruct level: :error,
            excluded_domains: [:cowboy],
            metadata: [],
            capture_log_messages: false

  ## Logger handler callbacks

  # Callback for :logger handlers
  @doc false
  @spec adding_handler(:logger.handler_config()) :: {:ok, :logger.handler_config()}
  def adding_handler(config) do
    valid_config_keys = [:excluded_domains, :capture_log_messages, :metadata, :level]

    config_attrs = Map.take(config.config, valid_config_keys)

    {:ok, put_in(config.config, struct!(__MODULE__, config_attrs))}
  end

  # Callback for :logger handlers
  @doc false
  @spec changing_config(:update, :logger.handler_config(), :logger.handler_config()) ::
          {:ok, :logger.handler_config()}
  def changing_config(:update, old_config, new_config) do
    valid_config_keys = [:excluded_domains, :capture_log_messages, :metadata, :logger]

    config_attrs = Map.take(new_config.config, valid_config_keys)

    {:ok, update_in(old_config.config, &Map.merge(&1, config_attrs))}
  end

  # Callback for :logger handlers
  @doc false
  @spec log(:logger.log_event(), :logger.handler_config()) :: :ok
  def log(%{} = log_event, %{config: %__MODULE__{} = config}) do
    # Logger handlers run in the process that logs, so we already read all the
    # necessary Sentry context from the process dictionary (when creating the event).
    # If we take meta[:sentry] here, we would duplicate all the stuff. This
    # behavior is different than the one in Sentry.LoggerBackend because the Logger
    # backend runs in its own process.
    opts =
      LoggerUtils.build_sentry_options(
        log_event.level,
        _sentry_context = nil,
        log_event.meta,
        config.metadata
      )

    cond do
      Logger.compare_levels(log_event.level, config.level) == :lt ->
        :skip

      excluded_domain?(config, log_event) ->
        :skip

      crash_reason = log_event.meta[:crash_reason] ->
        case crash_reason do
          {exception, stacktrace} when is_exception(exception) and is_list(stacktrace) ->
            Sentry.capture_exception(exception, Keyword.put(opts, :stacktrace, stacktrace))

          {reason, stacktrace} when is_list(stacktrace) ->
            opts =
              opts
              |> Keyword.put(:stacktrace, stacktrace)
              |> Keyword.update!(:extra, &Map.put(&1, :crash_reason, inspect(reason)))

            case msg_to_binary(log_event.msg) do
              {:ok, msg} -> Sentry.capture_message(msg, opts)
              :error -> :ok
            end
        end

      config.capture_log_messages ->
        case msg_to_binary(log_event.msg) do
          {:ok, msg} -> Sentry.capture_message(msg, opts)
          :error -> :ok
        end

      true ->
        :skip
    end
  end

  ## Helpers

  defp msg_to_binary({:string, string}) do
    {:ok, :unicode.characters_to_binary(string)}
  rescue
    _ -> :error
  end

  defp excluded_domain?(
         %__MODULE__{excluded_domains: excluded_domains},
         %{meta: meta} = _log_event
       ) do
    LoggerUtils.excluded_domain?(Map.get(meta, :domain, []), excluded_domains)
  end
end
