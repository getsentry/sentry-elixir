use Mix.Config

config :sentry_elixir,
  included_environments: [:prod],
  client: Sentry.Client

import_config "#{Mix.env}.exs"
