# Upgrade to Sentry 14.x

This guide contains information on how to upgrade from Sentry `13.x` to Sentry `14.x`. If you're on a version lower than `13.x`, see the previous upgrade guides to get to `13.x` before going through this one.

## Replace `:enable_logs` with `:logs`

The `:enable_logs` option was removed. Sentry validates its configuration when it starts, so an application that still sets `:enable_logs` fails to boot.

Setting the `:logs` option now attaches the Sentry logger handler, and setting `:level` inside it turns on structured logs. `:level` now defaults to `nil` instead of `:info`.

If you had `enable_logs: true`, move it into `:logs` as a `:level`:

```elixir
# In config/config.exs

# Replace this:
config :sentry,
  enable_logs: true,
  logs: [metadata: [:request_id]]

# with this:
config :sentry,
  logs: [level: :info, metadata: [:request_id]]
```

If you only delete `enable_logs: true` and keep a `:logs` block without `:level`, your application still reports crashes but stops sending structured logs.

If you had `enable_logs: false`, delete it along with any `:logs` block, since a `:logs` block now attaches the handler.

If you attach `Sentry.LoggerHandler` yourself, it sends structured logs when `:logs` has a `:level`, or when you pass `:logs_level` to the handler.

## Remove `:enable_metrics`

The `:enable_metrics` option was removed and metrics are always on. An application that still sets it fails to boot.

If you had `enable_metrics: false`, delete it. To stop metrics from being sent, drop them in a `:before_send_metric` callback:

```elixir
# In config/config.exs
config :sentry,
  before_send_metric: {MyApp.Sentry, :drop_metric}
```

```elixir
defmodule MyApp.Sentry do
  def drop_metric(_metric), do: nil
end
```

## Decide Whether to Trace 404 Responses

The new `:traces_ignore_http_status_codes` option defaults to `[404]`, so incoming requests answered with *404 Not Found* are no longer reported as transactions. Outgoing requests aren't affected.

```elixir
# In config/config.exs

# Trace every response, as before:
config :sentry,
  traces_ignore_http_status_codes: []

# Or ignore more statuses:
config :sentry,
  traces_ignore_http_status_codes: [404, 500..599]
```

The transaction is dropped only once the response status is known, so the trace has already been propagated as sampled. Services called while handling the request still report their spans, which appear in Sentry without their root transaction.
