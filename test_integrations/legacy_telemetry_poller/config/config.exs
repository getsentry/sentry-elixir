import Config

config :sentry,
  dsn: nil,
  environment_name: :test,
  test_mode: true,
  send_result: :sync,
  client: Sentry.HackneyClient,
  metrics: [runtime: [enabled: true]]

config :logger, level: :warning
