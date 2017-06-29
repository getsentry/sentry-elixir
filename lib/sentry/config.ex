defmodule Sentry.Config do
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

  def included_environments do
    Application.get_env(:sentry, :included_environments, @default_included_environments)
  end

  def environment_name do
    Application.get_env(:sentry, :environment_name, @default_environment_name)
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
    Application.get_env(:sentry, :release)
  end

  def server_name do
    Application.get_env(:sentry, :server_name)
  end

  def filter do
    Application.get_env(:sentry, :filter, Sentry.DefaultEventFilter)
  end

  def client do
    Application.get_env(:sentry, :client, Sentry.Client)
  end

  def use_error_logger do
    Application.get_env(:sentry, :use_error_logger, false)
  end

  def root_path do
    Application.fetch_env!(:sentry, :root_source_code_path)
  end

  def path_pattern do
    Application.get_env(:sentry, :source_code_path_pattern, @default_path_pattern)
  end

  def exclude_patterns do
    Application.get_env(:sentry, :source_code_exclude_patterns, @default_exclude_patterns)
  end

  def context_lines do
    Application.get_env(:sentry, :context_lines, @default_context_lines)
  end

  def in_app_module_whitelist do
    Application.get_env(:sentry, :in_app_module_whitelist, [])
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
end
