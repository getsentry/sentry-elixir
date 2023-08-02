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

## Fix Your Environment Variables

Sentry 9.0.0 stops using many "magic" system environment variables for configuration. These were environment variables prefixed with `SENTRY_`.

If you were using these environment variables, you'll either need to configure the corresponding setting through the application environment, or you'll need to *read* those variables yourself (at **runtime**).

For example, if you were setting `SENTRY_LOG_LEVEL`, you'll have to do something like:

```elixir
# In config/runtime.exs
config :sentry,
  log_level: System.fetch_env!("SENTRY_LOG_LEVEL")
```

We strongly recommend you do this in `config/runtime.exs` so that you'll read the system environment when starting your application. This is going to work both for local development as well as in [Mix releases](https://hexdocs.pm/mix/1.15.4/Mix.Tasks.Release.html).

This is the new system environment variables configuration:

| System environment variable | Corresponding configuration setting | Supported in 9.0.0+           |
| --------------------------- | ----------------------------------- | ----------------------------- |
| `SENTRY_SERVER_NAME`        | `:server_name`                      | ❌                            |
| `SENTRY_LOG_LEVEL`          | `:log_level`                        | ❌                            |
| `SENTRY_CONTEXT_LINES`      | `:context_lines`                    | ❌                            |
| `SENTRY_ENVIRONMENT_NAME`   | `:environment_name`                 | ❌ — use `SENTRY_ENVIRONMENT` |
| `SENTRY_ENVIRONMENT`        | `:environment_name`                 | ✅                            |
| `SENTRY_DSN`                | `:dsn`                              | ✅                            |
| `SENTRY_RELEASE`            | `:release`                          | ✅                            |

## Fix Compile-Time Configuration

Some configuration settings that Sentry supports are needed to **compile** Sentry itself. Before 9.0.0, you could change the value of these settings (such as `:enable_source_code_context`) at runtime, but it would have no effect. It would only do something if you were to change the value at compile time, and then you'd *recompile* Sentry itself.

Elixir v1.10.0 introduced [`Application.compile_env/2`](https://hexdocs.pm/elixir/1.15.4/Application.html#compile_env/2) however. This means that we were able to turn those settings into explicit *compile-time settings*. If you change the value of any of these settings now and forget to recompile Sentry, Mix will yell at you.

The fix for this is simple: do what Mix says.

The settings that are now *compile-time settings* are:

  * `:enable_source_code_context`
  * `:root_source_code_paths`
  * `:report_deps`
  * `:source_code_path_pattern`
  * `:source_code_exclude_patterns`
