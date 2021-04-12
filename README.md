# sentry

[![Build Status](https://img.shields.io/travis/getsentry/sentry-elixir.svg?style=flat)](https://travis-ci.org/getsentry/sentry-elixir)
[![hex.pm version](https://img.shields.io/hexpm/v/sentry.svg?style=flat)](https://hex.pm/packages/sentry)
[Documentation](https://hexdocs.pm/sentry/readme.html)

The Official Sentry Client for Elixir which provides a simple API to capture exceptions, automatically handle Plug Exceptions and provides a backend for the Elixir Logger. This documentation represents unreleased features, for documentation on the current release, see [here](https://hexdocs.pm/sentry/readme.html).

## Note on upgrading from Sentry 7.x to 8.x

Sentry 8.x requires Elixir 1.10 and Sentry 7.x will be maintained for applications running prior versions. Documentation for Sentry 7.x can be found [here](https://hexdocs.pm/sentry/7.2.4/readme.html).

If you would like to upgrade a project to use Sentry 8.x, see [here](https://gist.github.com/mitchellhenke/dce120a5515565076b13962ee0be749b).

## Installation

To use Sentry with your projects, edit your mix.exs file and add it as a dependency. Sentry does not install a JSON library nor HTTP client by itself.  Sentry will default to trying to use Jason for JSON operations and Hackney for HTTP requests, but can be configured to use other ones. To use the default ones, do:

```elixir
defp deps do
  [
    # ...
    {:sentry, "8.0.0"},
    {:jason, "~> 1.1"},
    {:hackney, "~> 1.8"},
    # if you are using plug_cowboy
    {:plug_cowboy, "~> 2.3"},
  ]
end
```

### Setup with Plug and Phoenix
Capturing errors in Plug applications is done with `Sentry.PlugContext` and `Sentry.PlugCapture`. `Sentry.PlugContext` adds contextual metadata from the current request which is then included in errors that are captured and reported by `Sentry.PlugCapture`.

If you are using Phoenix, first add `Sentry.PlugCapture` above the `use Phoenix.Endpoint` line in your endpoint file. `Sentry.PlugContext` should be added below `Plug.Parsers`.

```diff
 defmodule MyAppWeb.Endpoint
+  use Sentry.PlugCapture
   use Phoenix.Endpoint, otp_app: :my_app
   # ...
   plug Plug.Parsers,
     parsers: [:urlencoded, :multipart, :json],
     pass: ["*/*"],
     json_decoder: Phoenix.json_library()

+  plug Sentry.PlugContext
```

If you are in a non-Phoenix Plug application, add `Sentry.PlugCapture` at the top of your Plug application, and add `Sentry.PlugContext` below `Plug.Parsers` (if it is in your stack).

```diff
 defmodule MyApp.Router do
   use Plug.Router
+  use Sentry.PlugCapture
   # ...
   plug Plug.Parsers,
     parsers: [:urlencoded, :multipart]
+  plug Sentry.PlugContext
```

#### Capturing User Feedback

If you would like to capture user feedback as described [here](https://docs.sentry.io/platforms/elixir/enriching-events/user-feedback/), the `Sentry.get_last_event_id_and_source()` function can be used to see if Sentry has sent an event within the current Plug process, and the source of that event. `:plug` will be the source for events coming from `Sentry.PlugCapture`. The options described in the Sentry documentation linked above can be encoded into the response as well.

An example Phoenix application setup that wanted to display the user feedback form on 500 responses on requests accepting HTML could look like:

```elixir
defmodule MyAppWeb.ErrorView do
  # ...
  def render("500.html", _assigns) do
    case Sentry.get_last_event_id_and_source() do
      {event_id, :plug} when is_binary(event_id) ->
        opts =
          # can do %{eventId: event_id, title: "My custom title"}
          %{eventId: event_id}
          |> Jason.encode!()

        ~E"""
          <script src="https://browser.sentry-cdn.com/5.9.1/bundle.min.js" integrity="sha384-/x1aHz0nKRd6zVUazsV6CbQvjJvr6zQL2CHbQZf3yoLkezyEtZUpqUNnOLW9Nt3v" crossorigin="anonymous"></script>
          <script>
            Sentry.init({ dsn: '<%= Sentry.Config.dsn() %>' });
            Sentry.showReportDialog(<%= raw opts %>)
          </script>
        """

      _ ->
        "Error"
    end
  # ...
  end
```

### Capture Crashed Process Exceptions

This library comes with an extension to capture all error messages that the Plug handler might not.  This is based on [Logger.Backend](https://hexdocs.pm/logger/Logger.html#module-backends). You can add it as a backend when your application starts:

```diff
# lib/my_app/application.ex

+   def start(_type, _args) do
+     Logger.add_backend(Sentry.LoggerBackend)
```

The backend can also be configured to capture Logger metadata, which is detailed [here](https://hexdocs.pm/sentry/Sentry.LoggerBackend.html).

### Capture Arbitrary Exceptions

Sometimes you want to capture specific exceptions.  To do so, use `Sentry.capture_exception/2`.

```elixir
try do
  ThisWillError.really()
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

The `environment_name` and `included_environments` work together to determine
if and when Sentry should send events to the server. If the currently configured
`:environment_name` is in the configured list of `:included_environments`, the
event will be sent.

The full range of options is the following:

| Key           | Required         | Default      | Notes |
| ------------- | -----------------|--------------|-------|
| `dsn` | True  | n/a | |
| `environment_name` | False  | :prod | |
| `included_environments` | False  | `[:test, :dev, :prod]` | If you need non-standard mix env names you *need* to include it here |
| `tags` | False  | `%{}` | |
| `release` | False  | None | |
| `server_name` | False  | None | |
| `client` | False  | `Sentry.HackneyClient` | If you need different functionality for the HTTP client, you can define your own module that implements the `Sentry.HTTPClient` behaviour and set `client` to that module |
| `hackney_opts` | False  | `[pool: :sentry_pool]` | |
| `hackney_pool_max_connections` | False  | 50 | |
| `hackney_pool_timeout` | False  | 5000 | |
| `before_send_event` | False | | |
| `after_send_event` | False | | |
| `sample_rate` | False | 1.0 | |
| `send_result` | False | `:none` | You may want to set it to `:sync` if testing your Sentry integration. See "Testing with Sentry" |
| `send_max_attempts` | False | 4 | |
| `in_app_module_allow_list` | False | `[]` | |
| `report_deps` | False | True | Will attempt to load Mix dependencies at compile time to report alongside events |
| `enable_source_code_context` | False | False | |
| `root_source_code_paths` | Required if `enable_source_code_context` is enabled | | Should usually be set to `[File.cwd!()]`. For umbrella applications you should list all your applications paths in this list (e.g. `["#{File.cwd!()}/apps/app_1", "#{File.cwd!()}/apps/app_2"]`. |
| `context_lines` | False  | 3 | |
| `source_code_exclude_patterns` | False  | `[~r"/_build/", ~r"/deps/", ~r"/priv/"]` | |
| `source_code_path_pattern` | False  | `"**/*.ex"` | |
| `filter` | False | | Module where the filter rules are defined (see [Filtering Exceptions](https://hexdocs.pm/sentry/Sentry.html#module-filtering-exceptions)) |
| `json_library` | False | `Jason` | |
| `log_level` | False | `:warn` | This sets the log level used when Sentry fails to send an event due to an invalid event or API error |
| `max_breadcrumbs` | False | 100 | This sets the maximum number of breadcrumbs to send to Sentry when creating an event |

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
