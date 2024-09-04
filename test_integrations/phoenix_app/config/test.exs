import Config

# Configure your database
config :phoenix_app, PhoenixApp.Repo,
  adapter: Ecto.Adapters.SQLite3,
  database: "db/test.sqlite3"

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :phoenix_app, PhoenixAppWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "dauObqu/bn/QVNveb8VvMQgGyMdMsgV8EyCzibteBO4WNfKV6/GmG7Ymi+YyTrPd",
  server: false

# In test we don't send emails
config :phoenix_app, PhoenixApp.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

config :sentry,
  dsn: nil,
  environment_name: :dev,
  enable_source_code_context: true,
  send_result: :sync,
  test_mode: true
