use Mix.Config

config :sentry_elixir,
  included_environments: [:prod],

import_config "#{Mix.env}.exs"
