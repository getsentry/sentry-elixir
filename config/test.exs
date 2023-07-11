import Config

config :sentry,
  environment_name: :test,
  included_environments: [:test],
  hackney_opts: [recv_timeout: 50],
  send_result: :sync,
  send_max_attempts: 1

config :phoenix, :json_library, Jason
