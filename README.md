# sentry

[![Build Status](https://img.shields.io/travis/getsentry/sentry-elixir.svg?style=flat)](https://travis-ci.org/getsentry/sentry-elixir)
[![hex.pm version](https://img.shields.io/hexpm/v/sentry.svg?style=flat)](https://hex.pm/packages/sentry)

The Official Sentry Client for Elixir which provides a simple API to capture exceptions, automatically handle Plug Exceptions and provides a backend for the Elixir Logger.

[Documentation](https://hexdocs.pm/sentry/readme.html)

## Installation

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

Sometimes you want to capture specific exceptions, to do so use the `Sentry.capture_exception/3`.

```elixir
try do
  ThisWillError.reall()
rescue
  my_exception ->
    Sentry.capture_exception(my_exception, [stacktrace: System.stacktrace(), extra: %{extra: information}])
end
```

For optional settings check the [docs](https://hexdocs.pm/sentry/readme.html).

### Setup with Plug or Phoenix

In your router add the following lines:

```elixir
use Plug.ErrorHandler
use Sentry.Plug
```

### Capture all Exceptions

This library comes with an extension to capture all Error messages that the Plug handler might not. Simply set `use_error_logger` to true.

This is based on the Erlang [error_logger](http://erlang.org/doc/man/error_logger.html).

```elixir
config :sentry,
  use_error_logger: true
```

## Configuration

| Key           | Required         | Default      | Notes |
| ------------- | -----------------|--------------|-------|
| `dsn` | True  | n/a | |
| `environment_name` | False  | `MIX_ENV` | |
| `included_environments` | False  | `~w(prod test dev)a` | If you need non-standard mix env names you *need* to include it here |
| `tags` | False  | `%{}` | |
| `release` | False  | None | |
| `server_name` | False  | None | |
| `use_error_logger` | False  | False | |

## Testing Your Configuration

To ensure you've set up your configuration correctly we recommend running the
included mix task.  It can be tested on different Mix environments and will tell you if it is not currently configured to send events in that environment:

```bash
$ MIX_ENV=dev mix sentry.send_test_event
Client configuration:
server: https://sentry.io/
public_key: public
secret_key: secret
included_environments: [:prod]
current environment_name: :dev

:dev is not in [:prod] so no test event will be sent

$ MIX_ENV=prod mix sentry.send_test_event
Client configuration:
server: https://sentry.io/
public_key: public
secret_key: secret
included_environments: [:prod]
current environment_name: :prod

Sending test event!
```

A couple of things to note:

* This won't test your environment configuration. The test CLI forces your
  configuration to represent itself as if it were running in the production env.
* If you're running within Rails (or anywhere else that will bootstrap the
  rake environment), you should be able to omit the DSN argument.


## Docs

To build the docs locally, you'll need the [Sphinx](http://www.sphinx-doc.org/en/stable/):

```
$ pip install sphinx
```

Once Sphinx is available building the docs is simply:

```
$ make docs
```

You can then view the docs in your browser:

```
$ open docs/_build/html/index.html
```

## License

This project is Licensed under the [MIT License](https://github.com/getsentry/sentry-elixir/blob/master/LICENSE).
