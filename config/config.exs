import Config

json_library =
  if Version.compare(System.version(), "1.18.0") == :lt do
    Jason
  else
    JSON
  end

if config_env() == :test do
  config :sentry,
    environment_name: :test,
    json_library: json_library,
    tags: %{},
    enable_source_code_context: true,
    root_source_code_paths: [File.cwd!()],
    hackney_opts: [recv_timeout: 50, pool: :sentry_pool],
    send_result: :sync,
    send_max_attempts: 1,
    dedup_events: false,
    test_mode: true

  config :logger, backends: []
end

config :phoenix, :json_library, json_library
