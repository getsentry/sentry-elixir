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

An example production config might look like this:

```elixir
config :sentry,
  dsn: "https://public:secret@app.getsentry.com/1",
  environment_name: :prod,
  included_environments: [:prod],
  tags: %{
    env: "production"
  }
```

The environment

The `environment_name` and `included_environments` work together to determine
if and when Sentry should record exceptions. The `environment_name` is the
name of the current environment. In the example above, we have explicitly set
the environment to `:prod` which works well if you are inside an environment
specific configuration like `config/prod.exs`.

Alternatively, you could use Mix.env in your general configuration file:

```elixir
config :sentry, dsn: "https://public:secret@app.getsentry.com/1"
  included_environments: [:prod],
  environment_name: Mix.env
```

You can even rely on more custom determinations of the environment name. It's
not uncommmon for most applications to have a "staging" environment. In order
to handle this without adding an additional Mix environment, you can set an
environment variable that determines the release level.

```elixir
config :sentry, dsn: "https://public:secret@app.getsentry.com/1"
  included_environments: ~w(production staging),
  environment_name: System.get_env("RELEASE_LEVEL") || "development"
```

In this example, we are getting the environment name from the `RELEASE_LEVEL`
environment variable. If that variable does not exist, we default to `"development"`.
Now, on our servers, we can set the environment variable appropriately. On
our local development machines, exceptions will never be sent, because the
default value is not in the list of `included_environments`.

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
| `environment_name` | False  | `:dev` | |
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
