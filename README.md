# sentry

[![Build Status](https://img.shields.io/travis/getsentry/sentry-elixir.svg?style=flat)](https://travis-ci.org/getsentry/sentry-elixir)
[![hex.pm version](https://img.shields.io/hexpm/v/sentry.svg?style=flat)](https://hex.pm/packages/sentry)

The Official Sentry Client for Elixir which provides a simple API to capture exceptions, automatically handle Plug Exceptions and provides a backend for the Elixir Logger.

[Documentation](https://hexdocs.pm/sentry/readme.html)

## Note on upgrading from Sentry 6.x to 7.x

Elixir 1.7 and Erlang/OTP 21 significantly changed how errors are transmitted (See "Erlang/OTP logger integration" [here](https://elixir-lang.org/blog/2018/07/25/elixir-v1-7-0-released/)).  Sentry integrated heavily with Erlang's `:error_logger` module, but it is no longer the suggested path towards handling errors.

Sentry 7.x requires Elixir 1.7 and Sentry 6.x will be maintained for applications running prior versions.  Documentation for Sentry 6.x can be found [here](https://hexdocs.pm/sentry/6.4.2/readme.html).

If you would like to upgrade a project to use Sentry 7.x, see [here](https://gist.github.com/mitchellhenke/4ab6dd8d0ebeaaf9821fb625e0037a4d).

## Installation

To use Sentry with your projects, edit your mix.exs file and add it as a dependency.  Sentry does not install a JSON library itself, and requires users to have one available.  Sentry will default to trying to use Jason for JSON operations, but can be configured to use other ones.

```elixir
defp deps do
  [
    # ...
    {:sentry, "~> 7.0"},
    {:jason, "~> 1.1"},
  ]
end
```

### Setup with Plug or Phoenix

In your Plug.Router or Phoenix.Router, add the following lines:

```elixir
use Plug.ErrorHandler
use Sentry.Plug
```

If you are using Phoenix, you can also include [Sentry.Phoenix.Endpoint](https://hexdocs.pm/sentry/Sentry.Phoenix.Endpoint.html) in your Endpoint. This module captures errors occurring in the Phoenix pipeline before the request reaches the Router:

```elixir
use Phoenix.Endpoint, otp_app: :my_app
use Sentry.Phoenix.Endpoint
```

More information on why this may be necessary can be found here: https://github.com/getsentry/sentry-elixir/issues/229 and https://github.com/phoenixframework/phoenix/issues/2791

### Capture Crashed Process Exceptions

This library comes with an extension to capture all error messages that the Plug handler might not.  This is based on [Logger.Backend](https://hexdocs.pm/logger/Logger.html#module-backends).

To set this up, add `{:ok, _} = Logger.add_backend(Sentry.LoggerBackend)` to your application's start function. Example:

```elixir
def start(_type, _opts) do
  children = [
    supervisor(MyApp.Repo, []),
    supervisor(MyAppWeb.Endpoint, [])
  ]

  opts = [strategy: :one_for_one, name: MyApp.Supervisor]

  {:ok, _} = Logger.add_backend(Sentry.LoggerBackend)

  Supervisor.start_link(children, opts)
end
```

### Capture Arbitrary Exceptions

Sometimes you want to capture specific exceptions.  To do so, use `Sentry.capture_exception/2`.

```elixir
try do
  ThisWillError.reall()
rescue
  my_exception ->
    Sentry.capture_exception(my_exception, [stacktrace: __STACKTRACE__, extra: %{extra: information}])
end
```

### Capture Non-Exception Events

Sometimes you want to capture messages that are not Exceptions.

```elixir
    Sentry.capture_message("custom_event_name", extra: %{extra: information})
```

For optional settings check the [docs](https://hexdocs.pm/sentry/readme.html).


## Configuration

| Key           | Required         | Default      | Notes |
| ------------- | -----------------|--------------|-------|
| `dsn` | True  | n/a | |
| `environment_name` | False  | `:dev` | |
| `included_environments` | False  | `[:test, :dev, :prod]` | If you need non-standard mix env names you *need* to include it here |
| `tags` | False  | `%{}` | |
| `release` | False  | None | |
| `server_name` | False  | None | |
| `client` | False  | `Sentry.Client` | If you need different functionality for the HTTP client, you can define your own module that implements the `Sentry.HTTPClient` behaviour and set `client` to that module |
| `hackney_opts` | False  | `[pool: :sentry_pool]` | |
| `hackney_pool_max_connections` | False  | 50 | |
| `hackney_pool_timeout` | False  | 5000 | |
| `before_send_event` | False | | |
| `after_send_event` | False | | |
| `sample_rate` | False | 1.0 | |
| `in_app_module_whitelist` | False | `[]` | |
| `report_deps` | False | True | Will attempt to load Mix dependencies at compile time to report alongside events |
| `enable_source_code_context` | False | False | |
| `root_source_code_path` | Required if `enable_source_code_context` is enabled | | Should generally be set to `File.cwd!`|
| `context_lines` | False  | 3 | |
| `source_code_exclude_patterns` | False  | `[~r"/_build/", ~r"/deps/", ~r"/priv/"]` | |
| `source_code_path_pattern` | False  | `"**/*.ex"` | |
| `filter` | False | | Module where the filter rules are defined (see [Filtering Exceptions](https://hexdocs.pm/sentry/Sentry.html#module-filtering-exceptions)) |
| `json_library` | False | `Jason` | |

An example production config might look like this:

```elixir
config :sentry,
  dsn: "https://public_key@app.getsentry.com/1",
  environment_name: :prod,
  included_environments: [:prod],
  enable_source_code_context: true,
  root_source_code_path: File.cwd!,
  tags: %{
    env: "production"
  },
  hackney_opts: [pool: :my_pool],
  in_app_module_whitelist: [MyApp]
```

The `environment_name` and `included_environments` work together to determine
if and when Sentry should record exceptions. The `environment_name` is the
name of the current environment. In the example above, we have explicitly set
the environment to `:prod` which works well if you are inside an environment
specific configuration like `config/prod.exs`.

Alternatively, you could use Mix.env in your general configuration file:

```elixir
config :sentry, dsn: "https://public_key@app.getsentry.com/1",
  included_environments: [:prod],
  environment_name: Mix.env
```

You can even rely on more custom determinations of the environment name. It's
not uncommon for most applications to have a "staging" environment. In order
to handle this without adding an additional Mix environment, you can set an
environment variable that determines the release level.

```elixir
config :sentry, dsn: "https://public_key@app.getsentry.com/1",
  included_environments: ~w(production staging),
  environment_name: System.get_env("RELEASE_LEVEL") || "development"
```

In this example, we are getting the environment name from the `RELEASE_LEVEL`
environment variable. If that variable does not exist, we default to `"development"`.
Now, on our servers, we can set the environment variable appropriately. On
our local development machines, exceptions will never be sent, because the
default value is not in the list of `included_environments`.

Sentry uses the [hackney HTTP client](https://github.com/benoitc/hackney) for HTTP requests.  Sentry starts its own hackney pool named `:sentry_pool` with a default connection pool of 50, and a connection timeout of 5000 milliseconds.  The pool can be configured with the `hackney_pool_max_connections` and `hackney_pool_timeout` configuration keys.  If you need to set other [hackney configurations](https://github.com/benoitc/hackney/blob/master/doc/hackney.md#request5) for things like a proxy, using your own pool or response timeouts, the `hackney_opts` configuration is passed directly to hackney for each request.

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

The best way to ensure source code is up to date is to recompile Sentry itself via `mix deps.compile sentry --force`.  It's possible to create a Mix Task alias in `mix.exs` to do this.  The example below would allow one to run `mix sentry_recompile` which will force recompilation of Sentry so it has the newest source and then compile the project:

```elixir
# mix.exs
defp aliases do
  [sentry_recompile: ["deps.compile sentry --force", "compile"]]
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
  MyModule.add(1, "a")
end
```

## License

This project is Licensed under the [MIT License](https://github.com/getsentry/sentry-elixir/blob/master/LICENSE).
