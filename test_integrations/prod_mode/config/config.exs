import Config

# This integration project runs the Sentry SDK with `test_mode: false` (the
# default), exercising the production code path that the main test suite
# cannot — the main suite forces `test_mode: true`, which enables per-test
# config isolation and the test collector. With test_mode disabled,
# user-provided callbacks must be dropped when DSN is `nil`, matching the
# no-op semantics that pre-13.0.0 had at the Sentry.send_event/2 layer.
#
# The Mix project itself is run under `MIX_ENV=prod` (see the parent
# `mix.exs` aliases) so that `Mix.env()`-gated configuration also reflects
# production.
config :sentry,
  dsn: nil,
  before_send: {ProdMode.Callback, :on_event},
  before_send_log: {ProdMode.Callback, :on_log},
  before_send_metric: {ProdMode.Callback, :on_metric}
