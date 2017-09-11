defmodule Sentry.Config do
  @moduledoc """
  This module provides the functionality for fetching configuration settings and their defaults.
  """

  @default_included_environments [:dev, :test, :prod]
  @default_environment_name Mix.env
  @default_max_hackney_connections 50
  @default_hackney_timeout 5000
  @default_exclude_patterns [~r"/_build/", ~r"/deps/", ~r"/priv/"]
  @default_path_pattern "**/*.ex"
  @default_context_lines 3
  @default_sample_rate 1.0

  def validate_config! do
  end

  def dsn do
    get_config(:dsn, check_dsn: false)
  end

  def included_environments do
    get_config(:included_environments, default: @default_included_environments, check_dsn: false)
  end

  def environment_name do
    get_config(:environment_name, default: @default_environment_name)
  end

  def max_hackney_connections do
    get_config(:hackney_pool_max_connections, default: @default_max_hackney_connections, check_dsn: false)
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
    get_config(:client, default: Sentry.Client, check_dsn: false)
  end

  def enable_source_code_context do
    get_config(:root_source_code_path, default: false, check_dsn: false)
  end

  def root_source_code_path do
    path = get_config(:root_source_code_path)

    if path do
      path
    else
      raise ArgumentError.exception(":root_source_code_path must be configured")
    end
  end

  def source_code_path_pattern do
    get_config(:source_code_path_pattern, default: @default_path_pattern, check_dsn: false)
  end

  def source_code_exclude_patterns do
    get_config(:source_code_exclude_patterns, default: @default_exclude_patterns, check_dsn: false)
  end

  def context_lines do
    get_config(:context_lines, default: @default_context_lines, check_dsn: false)
  end

  def in_app_module_whitelist do
    get_config(:in_app_module_whitelist, default: [], check_dsn: false)
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

  defp get_config(key, opts \\ []) when is_atom(key) do
    default = Keyword.get(opts, :default)
    check_dsn = Keyword.get(opts, :check_dsn, true)

    environment_result = case get_from_application_environment(key) do
      {:ok, value} -> {:ok, value}
      :not_found -> get_from_system_environment(config_key_to_system_environment_key(key))
    end

    result = case environment_result do
      {:ok, value} -> {:ok, value}
      :not_found -> if(check_dsn, do: get_from_dsn_query_string(Atom.to_string(key)), else: :not_found)
    end

    case result do
      {:ok, value} -> value
      :not_found -> default
    end
  end

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
      result = URI.decode_query(query)
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
    string_key = Atom.to_string(key)
                 |> String.upcase

    "SENTRY_#{string_key}"
  end
end
