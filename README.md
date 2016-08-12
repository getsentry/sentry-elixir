sentry_elixir
============

[![Build Status](https://img.shields.io/travis/getsentry/raven-elixir.svg?style=flat)](https://travis-ci.org/getsentry/raven-elixir)
[![hex.pm version](https://img.shields.io/hexpm/v/sentry_elixir.svg?style=flat)](https://hex.pm/packages/sentry_elixir)


# Getting Started

To use Sentry with your projects, edit your mix.exs file and add it as a dependency:

```elixir
defp deps do
  [{:sentry_elixir, "~> 0.0.5"}]
end
```

# Overview

The goal of this project is to provide a full-feature Sentry client based on the guidelines in [Writing a Client](https://docs.getsentry.com/hosted/clientdev/) on the Sentry documentation.

However currently it only supports a `Logger` backend that will parse stacktraces and log them to Sentry.

# Example

![Example](http://i.imgur.com/GM8kQYE.png)

# Usage

Setup the application environment in your config.

```elixir
config :sentry,
  dsn: "https://public:secret@app.getsentry.com/1",
  tags: %{
    env: "production"
  }
```

Install the Logger backend.

```elixir
config :logger, backends: [:console, Sentry.Logger]
```
