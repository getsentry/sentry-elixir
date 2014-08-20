raven-elixir
============

[![Build Status](https://img.shields.io/travis/vishnevskiy/raven-elixir.svg?style=flat)](https://travis-ci.org/vishnevskiy/raven-elixir)
[![hex.pm version](https://img.shields.io/hexpm/v/raven.svg?style=flat)](https://hex.pm/packages/raven)


# Getting Started

To use Raven with your projects, edit your mix.exs file and add it as a dependency:

```elixir
defp deps do
  [{:raven, "~> 0.0.1"}]
end
```

# Overview 

The goal of this project is to provide a full-feature Sentry client based on the guidelines in [Writing a Client](http://sentry.readthedocs.org/en/latest/developer/client/) on the Sentry documentation.

However currently it only supports a `Logger` backend that will parse stacktraces and log them to Sentry.

# Example

![Example](http://i.imgur.com/GM8kQYE.png)

# Usage

Setup the application environment in your config.

```elixir
config :raven,
  dsn: "https://public:secret@app.getsentry.com/1",
  tags: %{
    env: "production"
  }
```

Install the Logger backend.

```elixir
Logger.add_backend(Raven)
```
