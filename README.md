# Sentry

![Build Status](https://github.com/getsentry/sentry-elixir/actions/workflows/main.yml/badge.svg)
[![Hex Package](https://img.shields.io/hexpm/v/sentry.svg)](https://hex.pm/packages/sentry)
[![Hex Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/sentry)

The official Sentry client for Elixir which provides a simple API to capture exceptions, automatically handle Plug exceptions, and provides a backend for the Elixir Logger.

💁: This README documents unreleased features (from the `master` branch). For documentation on the current release, see [the official documentation][docs].

## Installation

To use Sentry in your project, add it as a dependency in your `mix.exs` file. Sentry does not install a JSON library nor HTTP client by itself. Sentry will default to trying to use [Jason] for JSON serialization and [Hackney] for HTTP requests, but can be configured to use other ones. To use the default ones, do:

```elixir
defp deps do
  [
    # ...

    {:sentry, "8.0.0"},
    {:jason, "~> 1.4"},
    {:hackney, "~> 1.19"}
  ]
end
```

## Usage

This is a short overview of how to use the library. For complete documentation, refer to [HexDocs][docs].

### Capture Crashed Process Exceptions

This library comes with a [`:logger` handler][logger-handlers] to capture error messages coming from process crashes. To enable this, add the handler when your application starts:

```diff
  def start(_type, _args) do
+   :logger.add_handler(:sentry_handler, Sentry.LoggerHandler, %{})

    # ...
  end
```

The handler can also be configured to capture `Logger` metadata. See the documentation [here](https://hexdocs.pm/sentry/Sentry.LoggerBackend.html).

### Capture Arbitrary Exceptions

Sometimes you want to capture specific exceptions manually. To do so, use [`Sentry.capture_exception/2`](https://hexdocs.pm/sentry/Sentry.html#capture_exception/2).

```elixir
try do
  ThisWillError.really()
rescue
  my_exception ->
    Sentry.capture_exception(my_exception, stacktrace: __STACKTRACE__)
end
```

### Capture Non-Exception Events

Sometimes you want to capture **messages** that are not exceptions. To do that, use [`Sentry.capture_message/2`](https://hexdocs.pm/sentry/Sentry.html#capture_exception/2):

```elixir
Sentry.capture_message("custom_event_name", extra: %{extra: information})
```

For optional settings check the [documentation][docs].

## Configuration

Sentry has a range of configuration options, but most applications will have a configuration that looks like the following:

```elixir
# config/config.exs
config :sentry,
  dsn: "https://public_key@app.getsentry.com/1",
  environment_name: Mix.env(),
  included_environments: [:prod],
  enable_source_code_context: true,
  root_source_code_paths: [File.cwd!()]
```

### Context and Breadcrumbs

Sentry has multiple options for including contextual information. They are organized into "Tags", "User", and "Extra", and Sentry's documentation on them is [here](https://docs.sentry.io/learn/context/).  Breadcrumbs are a similar concept and Sentry's documentation covers them [here](https://docs.sentry.io/learn/breadcrumbs/).

In Elixir this can be complicated due to processes being isolated from one another. Tags context can be set globally through configuration, and all contexts can be set within a process, and on individual events.  If an event is sent within a process that has some context configured it will include that context in the event.  Examples of each are below, and for more information see the documentation of [Sentry.Context](https://hexdocs.pm/sentry/Sentry.Context.html).

```elixir
# Global Tags context via configuration:

config :sentry,
  tags: %{my_app_version: "14.30.10"}
  # ...

# Process-based Context
Sentry.Context.set_extra_context(%{day_of_week: "Friday"})
Sentry.Context.set_user_context(%{id: 24, username: "user_username", has_subscription: true})
Sentry.Context.set_tags_context(%{locale: "en-us"})
Sentry.Context.add_breadcrumb(%{category: "web.request"})

# Event-based Context
Sentry.capture_exception(exception, [tags: %{locale: "en-us", }, user: %{id: 34},
  extra: %{day_of_week: "Friday"}, breadcrumbs: [%{timestamp: 1461185753845, category: "web.request"}]]
```

### Fingerprinting

By default, Sentry aggregates reported events according to the attributes of the event, but users may need to override this functionality via [fingerprinting](https://docs.sentry.io/learn/rollups/#customize-grouping-with-fingerprints).

To achieve that in Sentry Elixir, one can use the `before_send_event` configuration callback. If there are certain types of errors you would like to have grouped differently, they can be matched on in the callback, and have the fingerprint attribute changed before the event is sent. An example configuration and implementation could look like:

```elixir
# lib/sentry.ex
defmodule MyApp.Sentry
  def before_send(%{exception: [%{type: DBConnection.ConnectionError}]} = event) do
    %{event | fingerprint: ["ecto", "db_connection", "timeout"]}
  end

  def before_send(event) do
    event
  end
end

# config.exs
config :sentry,
  before_send_event: {MyApp.Sentry, :before_send},
  # ...
```

### Reporting Exceptions with Source Code

Sentry's server supports showing the source code that caused an error, but depending on deployment, the source code for an application is not guaranteed to be available while it is running.  To work around this, the Sentry library reads and stores the source code at compile time.  This has some unfortunate implications.  If a file is changed, and Sentry is not recompiled, it will still report old source code.

The best way to ensure source code is up to date is to recompile Sentry itself via `mix deps.compile sentry --force`.  It's possible to create a Mix Task alias in `mix.exs` to do this.  The example below allows one to run `mix sentry_recompile && mix compile` which will compile any uncompiled or changed parts of the application, and then force recompilation of Sentry so it has the newest source. The second `mix compile` is required due to Mix only invoking the same task once in an alias.

```elixir
# mix.exs
defp aliases do
  [sentry_recompile: ["compile", "deps.compile sentry --force"]]
end
```

For more documentation, see [Sentry.Sources](https://hexdocs.pm/sentry/Sentry.Sources.html).

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

## Testing with Sentry

In some cases, users may want to test that certain actions in their application cause a report to be sent to Sentry.  Sentry itself does this by using [Bypass](https://github.com/PSPDFKit-labs/bypass).  It is important to note that when modifying the environment configuration the test case should not be run asynchronously.  Not returning the environment configuration to its original state could also affect other tests depending on how the Sentry configuration interacts with them.

Example:

```elixir
test "add/2 does not raise but sends an event to Sentry when given bad input" do
  bypass = Bypass.open()

  Bypass.expect(bypass, fn conn ->
    {:ok, _body, conn} = Plug.Conn.read_body(conn)
    Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
  end)

  Application.put_env(:sentry, :dsn, "http://public:secret@localhost:#{bypass.port}/1")
  Application.put_env(:sentry, :send_result, :sync)
  MyModule.add(1, "a")
end
```

When testing, you will also want to set the `send_result` type to `:sync`, so the request is done synchronously.

## License

This project is Licensed under the [MIT License](https://github.com/getsentry/sentry-elixir/blob/master/LICENSE).

[Jason]: https://github.com/michalmuskala/jason
[Hackney]: https://github.com/benoitc/hackney
[docs]: https://hexdocs.pm/sentry/readme.html
[logger-handlers]: https://www.erlang.org/doc/apps/kernel/logger_chapter#handlers
