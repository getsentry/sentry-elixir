# Upgrade to Sentry 10.x

This guide contains information on how to upgrade from Sentry `9.x` to Sentry `10.x`. If you're on a version lower than `9.x`, see the previous upgrade guides to get to `9.x` before going through this one.

## Actively Package Your Source Code

Before Sentry `10.0.0`, in order to report source code context around errors you had to configure Sentry through the `:enable_source_code_context`, `:root_source_code_paths`, and a few other options. These were **compile-time options**, meaning that if you changed any of these you had to recompile *the Sentry dependency itself*, not just your project. This was because Sentry used to store the raw source code of your application in its own compiled bytecode.

In Sentry `10.0.0`, we've revised this approach for a couple of reasons:

  * To avoid storing the raw source code in the compiled Sentry code, which in turn makes the BEAM bytecode artifact of your release smaller.

  * To simplify the compilation/recompilation step mentioned above.

Now, packaging source code is an active step that you have to take. The [`mix sentry.package_source_code`](`Mix.Tasks.Sentry.PackageSourceCode`) Mix task stores the source code in a compressed file inside the `priv` directory of the `:sentry` application. Sentry then loads this file when the `:sentry` application starts. This approach works well because users of Sentry are not interested in packaging source code within non-production environments, so this new task can be added to release scripts (or `Dockerfile`s, for example) only in production environments.

*All the configuration options related to source code remain the same*. See [the documentation in the `Sentry` module](Sentry.html#module-reporting-source-code).

### What Do I Have to Do?

  1. Add a call to `mix sentry.package_source_code` in your release script. This can be inside a `Dockerfile`, for example. Make sure to call this **before** `mix release`, so that the built release will include the packaged source code.

  1. That's all!

## Make Sure You're Using the Right Environment

Now, if you're not explicitly setting he `:environment_name` option in your config or setting the `SENTRY_ENVIRONMENT` environment variable, the environment will default to `production` (which is in line with the other Sentry SDKs).

## Rename `:before_send_event` to `:before_send`

To be in line with all other Sentry SDKs, we renamed the `:before_send_event` configuration option to `:before_send`. Just rename `:before_send_event` to `:before_send` in your configuration and potentially in any call where you pass it directly.

## Stop Using `:included_environments`

We hard-deprecated `:included_environments`. It's a bit of a confusing option that essentially no other Sentry SDKs use. To control whether to send events to Sentry, use the `:dsn` configuration instead (if set then we send events, if not set then we don't send events). `:included_environments` will be removed in v11.0.0.

For example, if you had something like this in `config/config.exs`:

```elixir
# In config/config.exs
config :sentry,
  dsn: "...",
  environment_name: config_env(),
  included_environments: [:prod]
```

Move this block to `config/prod.exs`, and turn it into:

```elixir
# In config/prod.exs
config :sentry,
  dsn: "...",
  environment_name: :prod
```

This way, `:dsn` will only be set in the `:prod` environment and no events will be sent in the development or testing environments.

Alternatively, if you were setting `:dsn` in `config/runtime.exs` (for use with Mix releases), change it to:

```elixir
# In config/runtime.exs
if config_env() == :prod do
  config :sentry,
    dsn: "...",
    environment_name: :prod
end
```
