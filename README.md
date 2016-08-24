# sentry_elixir

[![Build Status](https://img.shields.io/travis/getsentry/raven-elixir.svg?style=flat)](https://travis-ci.org/getsentry/raven-elixir)
[![hex.pm version](https://img.shields.io/hexpm/v/sentry_elixir.svg?style=flat)](https://hex.pm/packages/sentry_elixir)

Sentry Client for Elixir which provides a simple API to capture exceptions, automatically handle Plug Exceptions and provides a backend for the Elixir Logger.

## Getting Started

To use Sentry with your projects, edit your mix.exs file to add it as a dependency and add the `:sentry_elixir` package to your applications:

```elixir
defp application do
 [applications: [:sentry_elixir, :logger]]
end

defp deps do
  [{:sentry_elixir, "..."}]
end
```

Setup the application environment in your `config/prod.exs`

```elixir
config :sentry,
  dsn: "https://public:secret@app.getsentry.com/1",
  tags: %{
    env: "production"
  }
```

### Capture Exceptions
```elixir
Sentry.capture_exception(my_exception)
```

### Setup with Plug or Phoenix

In your router add the following lines

```elixir
use Plug.ErrorHandler
use Sentry.Plug
```


### Use the Logger Backend. 

Use this if you'd like to capture all Error messages that the Plug handler might not.

```elixir
config :logger, backends: [:console, Sentry.Logger]
```
