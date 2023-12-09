import Config

if config_env() == :test do
  config :sentry,
    environment_name: :test,
    tags: %{},
    enable_source_code_context: true,
    root_source_code_paths: [File.cwd!()],
    source_code_exclude_patterns: [],
    hackney_opts: [recv_timeout: 50, pool: :sentry_pool],
    send_result: :sync,
    send_max_attempts: 1,
    dedup_events: false

  config :logger, backends: []
end

config :phoenix, :json_library, Jason

config :sentry,
  dsn:
    "https://b3af41aceb36bd71d100d67b3b0af63b@o4506347701469184.ingest.sentry.io/4506347702779904",
  environment_name: :prod,
  enable_source_code_context: true,
  root_source_code_paths: [File.cwd!()],
  tags: %{
    env: "production"
  },
  included_environments: [:prod]
