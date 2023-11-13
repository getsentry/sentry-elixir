defmodule Sentry.LoggerUtils do
  @moduledoc false

  # Utilities that are shared between Sentry.LoggerHandler and Sentry.LoggerBackend.

  @spec build_sentry_options(Logger.level(), keyword() | nil, map(), [atom()] | :all) ::
          keyword()
  def build_sentry_options(level, sentry_context, meta, allowed_meta) do
    default_extra = %{logger_metadata: logger_metadata(meta, allowed_meta), logger_level: level}

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

  @spec excluded_domain?([atom()], [atom()]) :: boolean()
  def excluded_domain?(logged_domains, excluded_domains) do
    Enum.any?(logged_domains, &(&1 in excluded_domains))
  end

  defp elixir_logger_level_to_sentry_level(level) do
    case level do
      :emergency -> "fatal"
      :alert -> "fatal"
      :critical -> "fatal"
      :error -> "error"
      :warning -> "warning"
      :notice -> "info"
      :info -> "info"
      :debug -> "debug"
    end
  end

  defp get_sentry_options_from_callers([caller | rest]) when is_pid(caller) do
    with {:current_node, true} <- {:current_node, node(caller) == Node.self()},
         {:dictionary, [_ | _] = dictionary} <- :erlang.process_info(caller, :dictionary),
         %{sentry: sentry} <- dictionary[:"$logger_metadata$"] do
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
end
