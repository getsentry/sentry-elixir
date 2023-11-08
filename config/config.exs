import Config

if config_env() == :test do
  config :sentry,
    environment_name: :test,
    tags: %{},
    enable_source_code_context: true,
    root_source_code_paths: [File.cwd!()],
    source_code_exclude_patterns: [],
    hackney_opts: [recv_timeout: 50],
    send_result: :sync,
    send_max_attempts: 1

  config :logger, backends: []
end

config :phoenix, :json_library, Jason
