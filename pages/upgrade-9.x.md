# Upgrade to Sentry 9.x

This guide contains information on how to upgrade from Sentry 8.x to Sentry 9.x. If you're on a version lower than 8.x, see the previous upgrade guides to get to 8.x before going through this one.

## Check Your Elixir Version

Sentry 9.0.0 requires Elixir 1.11+. If you're still running on Elixir 1.10 or lower, use Sentry 8.x or lower.

## Remove DSN Query Params

Before 9.0.0, the Sentry Elixir library supported one way of passing configuration through **query parameters** in the configured Sentry DSN. This is **not supported** anymore in 9.0.0.

To upgrade:

  1. Remove query parameters from your configured Sentry DSN.
  1. Set the values for those parameters as normal configuration, either via the application environment, or via environment variables.

For example:

```elixir
# In config/config.exs

# Replace this:
config :sentry,
  dsn: "https://public:secret@app.getsentry.com/1?server_name=my-server"

# with this:
config :sentry,
  dsn: "https://public:secret@app.getsentry.com/1",
  server_name: "my-server"
```
