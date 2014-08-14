raven-elixir
============

[![Build Status](https://travis-ci.org/vishnevskiy/raven-elixir.svg?branch=master)](https://travis-ci.org/vishnevskiy/raven-elixir)

# Getting Started

To use Raven with your projects, edit your mix.exs file and add it as a dependency:

```elixir
defp deps do
  [{:raven, github: "vishnevskiy/raven-elixir"}]
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
  dsn: "https://public:secret@app.getsentry.com/1"
  tags: %{
    env: "production"
  }
```

Install the Logger backend.

```elixir
Logger.add_backend(Raven)
```
