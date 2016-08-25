use Mix.Config

config :sentry,
  included_environments: [:prod]

config :sasl,
  errlog_type: :error,
  sasl_error_logger: false

import_config "#{Mix.env}.exs"
