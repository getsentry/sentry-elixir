defmodule Sentry.Config do
  @moduledoc false

  @default_included_environments [:prod]
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

  @spec assert_dsn_has_no_query_params!() :: :ok
  def assert_dsn_has_no_query_params! do
    if sentry_dsn = dsn() do
      if URI.parse(sentry_dsn).query do
        raise ArgumentError, """
        using a Sentry DSN with query parameters is not supported since v9.0.0 of this library. \
        Please remove the query parameters from your DSN and pass them in as regular \
        configuration. See the documentation for the Sentry module for more information.\
        """
      end
    end

    :ok
  end

  @spec warn_for_deprecated_env_vars!() :: :ok
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
    get_config_from_app_or_system_env(:dsn, "SENTRY_DSN")
  end

  def included_environments do
    Application.get_env(:sentry, :included_environments, @default_included_environments)
  end

  def environment_name do
    if env = get_config_from_app_or_system_env(:environment_name, "SENTRY_ENVIRONMENT") do
      env
    else
      Application.put_env(:sentry, :environment_name, "dev")
      "dev"
    end
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
    get_config_from_app_or_system_env(:release, "SENTRY_RELEASE")
  end

  def server_name do
    Application.get_env(:sentry, :server_name)
  end

  def filter do
    Application.get_env(:sentry, :filter, Sentry.DefaultEventFilter)
  end

  def client do
    Application.get_env(:sentry, :client, Sentry.HackneyClient)
  end

  @enable_source_code_context Application.compile_env(:sentry, :enable_source_code_context, false)
  def enable_source_code_context, do: @enable_source_code_context

  if root_source_code_paths = Application.compile_env(:sentry, :root_source_code_paths, nil) do
    def root_source_code_paths, do: unquote(root_source_code_paths)
  else
    def root_source_code_paths do
      raise ArgumentError,
            ":root_source_code_paths must be configured if :enable_source_code_context is true"
    end
  end

  @source_code_path_pattern Application.compile_env(
                              :sentry,
                              :source_code_path_pattern,
                              @default_path_pattern
                            )
  def source_code_path_pattern, do: @source_code_path_pattern

  @source_code_exclude_patterns Application.compile_env(
                                  :sentry,
                                  :source_code_exclude_patterns,
                                  @default_exclude_patterns
                                )
  def source_code_exclude_patterns, do: @source_code_exclude_patterns

  def context_lines do
    Application.get_env(:sentry, :context_lines, @default_context_lines)
  end

  def in_app_module_allow_list do
    Application.get_env(:sentry, :in_app_module_allow_list, [])
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
    Application.get_env(:sentry, :before_send_event)
  end

  def after_send_event do
    Application.get_env(:sentry, :after_send_event)
  end

  @report_deps Application.compile_env(:sentry, :report_deps, true)
  def report_deps, do: @report_deps

  def json_library do
    Application.get_env(:sentry, :json_library, Jason)
  end

  def log_level do
    Application.get_env(:sentry, :log_level, @default_log_level)
  end

  def max_breadcrumbs do
    Application.get_env(:sentry, :max_breadcrumbs, 100)
  end

  defp get_config_from_app_or_system_env(app_key, system_env_key) do
    case Application.fetch_env(:sentry, app_key) do
      {:ok, {:system, env_key}} ->
        value = System.fetch_env!(env_key)
        Application.put_env(:sentry, app_key, value)
        value

      {:ok, value} ->
        value

      :error ->
        if value = System.get_env(system_env_key) do
          Application.put_env(:sentry, app_key, value)
          value
        else
          nil
        end
    end
  end
end
