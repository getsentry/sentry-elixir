# Oban Integration

The Sentry SDK supports integrating with [Oban](https://github.com/sorentwo/oban), one of the most widely-used job-scheduling libraries in the Elixir ecosystem.

The Oban integration is available since *v10.2.0* of the Sentry SDK, and it requires:

  1. Oban to be a dependency of your application.
  1. Oban version 2.17.6 or greater.
  1. Elixir 1.13 or later, since that is required by Oban itself.

## Automatic Error Capturing

*Available since 10.3.0*.

You can enable automatic capturing of errors that happen in Oban jobs. This includes jobs that return `{:error, reason}`, raise an exception, exit, and so on.

To enable support:

```elixir
config :sentry,
  integrations: [
    oban: [
      capture_errors: true
    ]
  ]
```

## Cron Support

To enable support for monitoring Oban jobs via [Sentry Cron](https://docs.sentry.io/product/crons/), make sure the following `:oban` configuration is in your Sentry configuration:

```elixir
config :sentry,
  # ...,
  integrations: [
    oban: [
      cron: [enabled: true]
    ]
  ]
```

This configuration will report started, completed, and failed job, alongside their duration. It will use the worker name as the `monitor_slug` of the reported cron.
