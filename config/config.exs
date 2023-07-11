import Config

config :sentry,
  included_environments: [:test],
  environment_name: :test,
  tags: %{},
  enable_source_code_context: true,
  root_source_code_paths: [File.cwd!()],
  hackney_opts: [recv_timeout: 50],
  send_result: :sync,
  send_max_attempts: 1

config :phoenix, :json_library, Jason
