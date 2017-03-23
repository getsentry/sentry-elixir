use Mix.Config

config :sentry,
  environment_name: :test,
  included_environments: [:test],
  client: Sentry.TestClient,
  hackney_opts: [recv_timeout: 50]
