use Mix.Config

config :sentry,
  environment_name: :test,
  client: Sentry.TestClient
