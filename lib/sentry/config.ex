defmodule Sentry.Config do
  @moduledoc """
  This module provides the functionality for fetching configuration settings and their defaults.

  Sentry supports loading config at runtime, via `{:system, "SYSTEM_ENV_KEY"}` tuples, where Sentry will read `SYSTEM_ENV_KEY` to get the config value from the system environment at runtime.
  """

  @default_included_environments [:prod]
  @default_environment_name Mix.env()
  @default_max_hackney_connections 50
  @default_hackney_timeout 5000
  @default_exclude_patterns [~r"/_build/", ~r"/deps/", ~r"/priv/"]
  @default_path_pattern "**/*.ex"
  @default_context_lines 3
  @default_sample_rate 1.0
  @default_send_result :none
  @default_send_max_attempts 4

  @permitted_log_level_values ~w(debug info warning warn error)a

  def validate_config! do
  end

  def dsn do
    get_config(:dsn, check_dsn: false)
  end

  @doc """
  The `:included_environments` config key expects a list, but if given a string, it will split the string on commas to create a list.
  """
  def included_environments do
    get_config(
      :included_environments,
      default: @default_included_environments,
      check_dsn: false,
      type: :list
    )
  end

  def environment_name do
    get_config(:environment_name, default: @default_environment_name)
  end

  def max_hackney_connections do
    get_config(
      :hackney_pool_max_connections,
      default: @default_max_hackney_connections,
      check_dsn: false
    )
  end

  def hackney_timeout do
    get_config(:hackney_pool_timeout, default: @default_hackney_timeout, check_dsn: false)
  end

  def tags do
    get_config(:tags, default: %{}, check_dsn: false)
  end

  def release do
    get_config(:release)
  end

  def server_name do
    get_config(:server_name)
  end

  def filter do
    get_config(:filter, default: Sentry.DefaultEventFilter, check_dsn: false)
  end

  def client do
    get_config(:client, default: Sentry.HackneyClient, check_dsn: false)
  end

  def enable_source_code_context do
    get_config(:enable_source_code_context, default: false, check_dsn: false)
  end

  @deprecated "Use root_source_code_paths/0 instead"
  def root_source_code_path do
    path = get_config(:root_source_code_path, check_dsn: false)

    if path do
      path
    else
      raise ArgumentError.exception(":root_source_code_path must be configured")
    end
  end

  # :root_source_code_path (single path) was replaced by :root_source_code_paths (list of
  # paths).
  #
  # In order for this to not be a breaking change we still accept the old
  # :root_source_code_path as a fallback.
  #
  # We should deprecate this the :root_source_code_path completely in the next major
  # release.
  def root_source_code_paths do
    paths = get_config(:root_source_code_paths, check_dsn: false)
    path = get_config(:root_source_code_path, check_dsn: false)

    cond do
      not is_nil(path) and not is_nil(paths) ->
        raise ArgumentError, """
        :root_source_code_path and :root_source_code_paths can't be configured at the \
        same time.

        :root_source_code_path is deprecated. Set :root_source_code_paths instead.
        """

      not is_nil(paths) ->
        paths

      not is_nil(path) ->
        [path]

      true ->
        raise ArgumentError.exception(":root_source_code_paths must be configured")
    end
  end

  def source_code_path_pattern do
    get_config(:source_code_path_pattern, default: @default_path_pattern, check_dsn: false)
  end

  def source_code_exclude_patterns do
    get_config(
      :source_code_exclude_patterns,
      default: @default_exclude_patterns,
      check_dsn: false
    )
  end

  def context_lines do
    get_config(:context_lines, default: @default_context_lines, check_dsn: false)
  end

  @deprecated "Use Sentry.Config.in_app_module_allow_list/0 instead."
  def in_app_module_whitelist do
    get_config(:in_app_module_whitelist, default: [], check_dsn: false)
  end

  def in_app_module_allow_list do
    new_config = get_config(:in_app_module_allow_list, default: [], check_dsn: false)
    old_config = get_config(:in_app_module_whitelist, check_dsn: false)

    cond do
      not is_nil(new_config) and not is_nil(old_config) ->
        raise ArgumentError, """
        :in_app_module_allow_list and :in_app_module_whitelist can't be configured at the \
        same time.

        :in_app_module_whitelist is deprecated. Set :in_app_module_allow_list instead.
        """

      not is_nil(old_config) ->
        IO.warn(
          "Sentry.Config.in_app_module_whitelist/0 is deprecated. Use Sentry.Config.in_app_module_allow_list/0 instead."
        )

        old_config

      true ->
        new_config
    end
  end

  def send_result do
    get_config(:send_result, default: @default_send_result, check_dsn: false)
  end

  def send_max_attempts do
    get_config(:send_max_attempts, default: @default_send_max_attempts, check_dsn: false)
  end

  def sample_rate do
    get_config(:sample_rate, default: @default_sample_rate, check_dsn: false)
  end

  def hackney_opts do
    get_config(:hackney_opts, default: [], check_dsn: false)
  end

  def before_send_event do
    get_config(:before_send_event, check_dsn: false)
  end

  def after_send_event do
    get_config(:after_send_event, check_dsn: false)
  end

  def report_deps do
    get_config(:report_deps, default: true, check_dsn: false)
  end

  def json_library do
    get_config(:json_library, default: Jason, check_dsn: false)
  end

  def log_level do
    get_config(:log_level, default: :warn, check_dsn: false)
  end

  def max_breadcrumbs do
    get_config(:max_breadcrumbs, default: 100, check_dsn: false)
  end

  def permitted_log_level_values, do: @permitted_log_level_values

  defp get_config(key, opts \\ []) when is_atom(key) do
    default = Keyword.get(opts, :default)
    check_dsn = Keyword.get(opts, :check_dsn, true)
    type = Keyword.get(opts, :type)

    result =
      with :not_found <- get_from_application_environment(key),
           env_key = config_key_to_system_environment_key(key),
           system_func = fn -> get_from_system_environment(env_key) end,
           :not_found <- save_system_to_application(key, system_func) do
        if check_dsn do
          query_func = fn -> key |> Atom.to_string() |> get_from_dsn_query_string() end
          save_system_to_application(key, query_func)
        else
          :not_found
        end
      end

    convert_type(result, type, default)
  end

  defp save_system_to_application(key, func) do
    case func.() do
      :not_found ->
        :not_found

      {:ok, value} ->
        Application.put_env(:sentry, key, value)
        {:ok, value}
    end
  end

  defp convert_type({:ok, value}, nil, _), do: value
  defp convert_type({:ok, value}, :list, _) when is_list(value), do: value
  defp convert_type({:ok, value}, :list, _) when is_binary(value), do: String.split(value, ",")
  defp convert_type(_, _, default), do: default

  defp get_from_application_environment(key) when is_atom(key) do
    case Application.fetch_env(:sentry, key) do
      {:ok, {:system, env_var}} -> get_from_system_environment(env_var)
      {:ok, value} -> {:ok, value}
      :error -> :not_found
    end
  end

  defp get_from_system_environment(key) when is_binary(key) do
    case System.get_env(key) do
      nil -> :not_found
      value -> {:ok, value}
    end
  end

  defp get_from_dsn_query_string(key) when is_binary(key) do
    sentry_dsn = dsn()

    if sentry_dsn do
      %URI{query: query} = URI.parse(sentry_dsn)
      query = query || ""

      result =
        URI.decode_query(query)
        |> Map.fetch(key)

      case result do
        {:ok, value} -> {:ok, value}
        :error -> :not_found
      end
    else
      :not_found
    end
  end

  defp config_key_to_system_environment_key(key) when is_atom(key) do
    string_key =
      Atom.to_string(key)
      |> String.upcase()

    "SENTRY_#{string_key}"
  end
end
