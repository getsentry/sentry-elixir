defmodule Sentry.LoggerUtils do
  @moduledoc false

  # Utilities that are shared between Sentry.LoggerHandler and Sentry.LoggerBackend, plus
  # functions that wrap Elixir's Logger and that make sure we use the right options for Logger
  # calls. For example, if we (the Sentry SDK) log without using `domain: [:sentry]`, then we can
  # run into loops in which Sentry reports messages that the SDK itself logs.

  alias Sentry.Config

  require Logger

  @spec build_sentry_options(Logger.level(), keyword() | nil, map(), [atom()] | :all) ::
          keyword()
  def build_sentry_options(level, sentry_context, meta, allowed_meta) do
    default_extra =
      Map.merge(
        %{logger_metadata: logger_metadata(meta, allowed_meta), logger_level: level},
        Map.take(meta, [:domain])
      )

    (sentry_context || get_sentry_options_from_callers(meta[:callers]) || %{})
    |> Map.new()
    |> Map.update(:extra, default_extra, &Map.merge(&1, default_extra))
    |> Map.merge(%{
      event_source: :logger,
      level: elixir_logger_level_to_sentry_level(level),
      result: :none
    })
    |> Map.to_list()
  end

  # Always excludes the :sentry domain, to avoid infinite logging loops.
  @spec excluded_domain?([atom()], [atom()]) :: boolean()
  def excluded_domain?(logged_domains, excluded_domains) do
    Enum.any?(logged_domains, &(&1 == :sentry or &1 in excluded_domains))
  end

  defp elixir_logger_level_to_sentry_level(level) do
    case level do
      :emergency -> :fatal
      :alert -> :fatal
      :critical -> :fatal
      :error -> :error
      :warning -> :warning
      :notice -> :info
      :info -> :info
      :debug -> :debug
    end
  end

  defp get_sentry_options_from_callers([caller | rest]) when is_pid(caller) do
    logger_metadata_key = Sentry.Context.__logger_metadata_key__()

    with {:current_node, true} <- {:current_node, node(caller) == Node.self()},
         {:dictionary, [_ | _] = dictionary} <- :erlang.process_info(caller, :dictionary),
         %{^logger_metadata_key => sentry} <- dictionary[:"$logger_metadata$"] do
      sentry
    else
      _ -> get_sentry_options_from_callers(rest)
    end
  end

  defp get_sentry_options_from_callers(_other) do
    nil
  end

  defp logger_metadata(meta, allowed_meta) do
    meta = Map.new(meta)

    # Filter allowed meta.
    meta =
      case allowed_meta do
        :all -> meta
        allowed_meta -> Map.take(meta, allowed_meta)
      end

    # Potentially convert to iodata.
    :maps.map(fn _key, val -> attempt_to_convert_iodata(val) end, meta)
  end

  defp attempt_to_convert_iodata(list) when is_list(list) do
    IO.chardata_to_string(list)
  rescue
    _exception -> list
  else
    str -> if String.printable?(str), do: str, else: list
  end

  defp attempt_to_convert_iodata(other) do
    other
  end

  @spec log(iodata() | (-> iodata()), keyword()) :: :ok
  def log(message_or_fun, meta \\ []) when is_list(meta) do
    meta = Keyword.merge(meta, domain: [:sentry])
    Logger.log(Config.log_level(), message_or_fun, meta)
  end
end
