defmodule Sentry.Config do
  @moduledoc false

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
  @default_log_level :warning

  @spec validate_log_level!() :: :ok
  def validate_log_level! do
    value = log_level()

    if value in ~w(debug info warning warn error)a do
      :ok
    else
      raise ArgumentError, "#{inspect(value)} is not a valid :log_level configuration"
    end
  end

  @spec validate_included_environments!() :: :ok
  def validate_included_environments! do
    case included_environments() do
      comma_separated_envs when is_binary(comma_separated_envs) ->
        IO.warn("""
        setting :included_environments to a comma-separated string is deprecated and won't \
        be supported in the next major version. Set :included_environments to a list of \
        atoms instead.\
        """)

        Application.put_env(
          :sentry,
          :included_environments,
          String.split(comma_separated_envs, ",")
        )

      list_of_atoms when is_list(list_of_atoms) ->
        :ok
    end

    :ok
  end

  @spec validate_json_config!() :: :ok
  def warn_for_deprecated_env_vars! do
    if is_nil(Application.get_env(:sentry, :included_environments)) &&
         System.get_env("SENTRY_INCLUDED_ENVIRONMENTS") do
      IO.warn("""
      setting SENTRY_INCLUDED_ENVIRONMENTS is deprecated and won't be supported in the \
      next major version. Set the :included_environments application configuration instead, \
      and use config/runtime.exs if you want to set it at runtime.
      """)
    end

    :ok
  end

  def dsn do
    get_config(:dsn, check_dsn: false)
  end

  def included_environments do
    Application.get_env(:sentry, :included_environments, @default_included_environments)
  end

  def environment_name do
    get_config(:environment_name, default: @default_environment_name)
  end

  def max_hackney_connections do
    Application.get_env(:sentry, :hackney_pool_max_connections, @default_max_hackney_connections)
  end

  def hackney_timeout do
    Application.get_env(:sentry, :hackney_pool_timeout, @default_hackney_timeout)
  end

  def tags do
    Application.get_env(:sentry, :tags, %{})
  end

  def release do
    get_config(:release)
  end

  def server_name do
    get_config(:server_name)
  end

  def filter do
    Application.get_env(:sentry, :filter, Sentry.DefaultEventFilter)
  end

  def client do
    Application.get_env(:sentry, :client, Sentry.HackneyClient)
  end

  def enable_source_code_context do
    get_config(:enable_source_code_context, default: false, check_dsn: false)
  end

  def root_source_code_paths do
    if paths = get_config(:root_source_code_paths, check_dsn: false) do
      paths
    else
      raise ArgumentError, ":root_source_code_paths must be configured"
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

  def in_app_module_allow_list do
    get_config(:in_app_module_allow_list, default: [], check_dsn: false)
  end

  def send_result do
    Application.get_env(:sentry, :send_result, @default_send_result)
  end

  def send_max_attempts do
    Application.get_env(:sentry, :send_max_attempts, @default_send_max_attempts)
  end

  def sample_rate do
    Application.get_env(:sentry, :sample_rate, @default_sample_rate)
  end

  def hackney_opts do
    Application.get_env(:sentry, :hackney_opts, [])
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
    Application.get_env(:sentry, :json_library, Jason)
  end

  def log_level do
    get_config(:log_level, default: @default_log_level, check_dsn: false)
  end

  def max_breadcrumbs do
    Application.get_env(:sentry, :max_breadcrumbs, 100)
  end

  defp get_config(key, opts \\ []) when is_atom(key) do
    default = Keyword.get(opts, :default)
    check_dsn = Keyword.get(opts, :check_dsn, true)

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

    case result do
      {:ok, value} -> value
      _other -> default
    end
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
