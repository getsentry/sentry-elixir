defmodule Sentry.Config do
  @moduledoc false

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

  @spec validate_environment_name!() :: :ok
  def validate_environment_name! do
    # This already raises if missing.
    environment_name()
    :ok
  end

  @spec validate_included_environments!() :: :ok
  def validate_included_environments! do
    normalized_environments =
      case included_environments() do
        comma_separated_envs when is_binary(comma_separated_envs) ->
          IO.warn("""
          setting :included_environments to a comma-separated string is deprecated and won't \
          be supported in the next major version. Set :included_environments to a list of \
          atoms instead.\
          """)

          String.split(comma_separated_envs, ",")

        list when is_list(list) ->
          Enum.map(list, fn
            env when is_atom(env) or is_binary(env) ->
              to_string(env)

            other ->
              raise ArgumentError, """
              expected environments in :included_environments to be atoms or strings, \
              got: #{inspect(other)}\
              """
          end)

        :all ->
          :all
      end

    :ok = Application.put_env(:sentry, :included_environments, normalized_environments)
  end

  @spec assert_dsn_has_no_query_params!() :: :ok
  def assert_dsn_has_no_query_params! do
    if sentry_dsn = dsn() do
      uri_dsn = URI.parse(sentry_dsn)

      if uri_dsn.query do
        raise ArgumentError, """
        using a Sentry DSN with query parameters is not supported since v9.0.0 of this library.
        The configured DSN was:

            #{inspect(sentry_dsn)}

        The query string in that DSN is:

            #{inspect(uri_dsn.query)}

        Please remove the query parameters from your DSN and pass them in as regular
        configuration. Check out the guide to upgrade to 9.0.0 at:

          https://hexdocs.pm/sentry/upgrade-9.x.html

        See the documentation for the Sentry module for more information on configuration
        in general.
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
    case Application.fetch_env(:sentry, :included_environments) do
      {:ok, :all} ->
        :all

      {:ok, envs} when is_list(envs) ->
        string_envs = Enum.map(envs, &to_string/1)
        Application.put_env(:sentry, :included_environments, string_envs)
        string_envs

      :error ->
        _default = ["prod"]
    end
  end

  def environment_name do
    get_config_from_app_or_system_env(:environment_name, "SENTRY_ENVIRONMENT") ||
      raise ":environment_name must be set in the application config or the SENTRY_ENVIRONMENT env var"
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
    case Application.get_env(:sentry, app_key, nil) do
      {:system, env_key} ->
        raise ArgumentError, """
        using {:system, env} as a configuration value is not supported since v9.0.0 of this \
        library. Move the configuration for #{inspect(app_key)} to config/runtime.exs, \
        and read the #{inspect(env_key)} environment variable from there:

          config :sentry,
            # ...,
            #{app_key}: System.fetch_env!(#{inspect(env_key)})

        """

      nil ->
        if value = System.get_env(system_env_key) do
          Application.put_env(:sentry, app_key, value)
          value
        else
          nil
        end

      value ->
        value
    end
  end
end
