# Oban Integration

The Sentry SDK supports integrating with [Oban](https://github.com/sorentwo/oban), one of the most widely-used job-scheduling libraries in the Elixir ecosystem.

The Oban integration is available since *v10.2.0* of the Sentry SDK, and it requires the Oban library to be a dependency. It also requires Elixir 1.13 or later, since that is required by Oban itself.

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
