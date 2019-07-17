use Mix.Config

config :sentry,
  environment_name: :test,
  included_environments: [:test],
  client: Sentry.TestClient,
  hackney_opts: [recv_timeout: 50],
  max_client_attempts: 1

config :ex_unit,
  assert_receive_timeout: 500
