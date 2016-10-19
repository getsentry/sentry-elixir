use Mix.Config

config :sentry,
  included_environments: [:test, :dev, :prod],
  environment_name: :dev,
  tags: %{}

import_config "#{Mix.env}.exs"
