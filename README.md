# sentry_elixir

[![Build Status](https://img.shields.io/travis/getsentry/raven-elixir.svg?style=flat)](https://travis-ci.org/getsentry/raven-elixir)
[![hex.pm version](https://img.shields.io/hexpm/v/sentry.svg?style=flat)](https://hex.pm/packages/sentry)

Sentry Client for Elixir which provides a simple API to capture exceptions, automatically handle Plug Exceptions and provides a backend for the Elixir Logger.

## Getting Started

To use Sentry with your projects, edit your mix.exs file to add it as a dependency and add the `:sentry` package to your applications:

```elixir
defp application do
 [applications: [:sentry, :logger]]
end

defp deps do
  [{:sentry, "~> 1.0"}]
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

### Capture all Exceptions

Use this if you'd like to capture all Error messages that the Plug handler might not. Simply set `use_error_logger` to true. 

This is based on the Erlang [error_logger](http://erlang.org/doc/man/error_logger.html).

```elixir
config :sentry_elixir,
  use_error_logger: true

```

## Configuration
| Key           | Required         | Default      |
| ------------- | -----------------|--------------|
| `dsn` | True  | n/a |
| `environment_name` | False  | `MIX_ENV` |
| `included_environments` | False  | `~w(prod test dev)a` |
| `tags` | False  | `%{}` |
| `release` | False  | None |
| `server_name` | False  | None |
| `use_error_logger` | False  | False |
