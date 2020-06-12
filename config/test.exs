use Mix.Config

config :sentry,
  environment_name: :test,
  included_environments: [:test],
  hackney_opts: [recv_timeout: 50],
  send_result: :sync,
  send_max_attempts: 1

config :ex_unit,
  assert_receive_timeout: 500
