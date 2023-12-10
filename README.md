<p align="center">
  <a href="https://sentry.io/?utm_source=github&utm_medium=logo" target="_blank">
    <img src="https://sentry-brand.storage.googleapis.com/sentry-wordmark-dark-280x84.png" alt="Sentry" width="280" height="84">
  </a>
</p>

_Bad software is everywhere, and we're tired of it. Sentry is on a mission to help developers write better software faster, so we can get back to enjoying technology. If you want to join us [<kbd>**Check out our open positions**</kbd>](https://sentry.io/careers/)_

![Build Status](https://github.com/getsentry/sentry-elixir/actions/workflows/main.yml/badge.svg)
[![Hex Package](https://img.shields.io/hexpm/v/sentry.svg)](https://hex.pm/packages/sentry)
[![Hex Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/sentry)

This is the official Sentry SDK for [Sentry].

*💁: This README documents unreleased features (from the `master` branch). For documentation on the current release, see [the official documentation][docs].*

## Getting Started

### Install

To use Sentry in your project, add it as a dependency in your `mix.exs` file. Sentry does not install a JSON library nor HTTP client by itself. Sentry will default to trying to use [Jason] for JSON serialization and [Hackney] for HTTP requests, but can be configured to use other ones. To use the default ones, do:

```elixir
defp deps do
  [
    # ...

    {:sentry, "~> 10.0"},
    {:jason, "~> 1.4"},
    {:hackney, "~> 1.19"}
  ]
end
```

### Configuration

Sentry has a range of configuration options, but most applications will have a configuration that looks like the following:

```elixir
# config/config.exs
config :sentry,
  dsn: "https://public_key@app.getsentry.com/1",
  environment_name: Mix.env(),
  enable_source_code_context: true,
  root_source_code_paths: [File.cwd!()]
```

### Usage

This library comes with a [`:logger` handler][logger-handlers] to capture error messages coming from process crashes. To enable this, add the handler when your application starts:

```diff
  def start(_type, _args) do
+   :logger.add_handler(:sentry_handler, Sentry.LoggerHandler, %{})

    # ...
  end
```

The handler can also be configured to capture `Logger` metadata. See the documentation [here](https://hexdocs.pm/sentry/Sentry.LoggerBackend.html).

Sometimes you want to capture specific exceptions manually. To do so, use [`Sentry.capture_exception/2`](https://hexdocs.pm/sentry/Sentry.html#capture_exception/2).

```elixir
try do
  ThisWillError.really()
rescue
  my_exception ->
    Sentry.capture_exception(my_exception, stacktrace: __STACKTRACE__)
end
```

Sometimes you want to capture **messages** that are not exceptions. To do that, use [`Sentry.capture_message/2`](https://hexdocs.pm/sentry/Sentry.html#capture_exception/2):

```elixir
Sentry.capture_message("custom_event_name", extra: %{extra: information})
```

To learn more about how to use this SDK, refer to [the documentation][docs].

#### Testing Your Configuration

To ensure you've set up your configuration correctly we recommend running the
included Mix task. It can be tested on different Mix environments and will tell you if it is not currently configured to send events in that environment:

```bash
MIX_ENV=dev mix sentry.send_test_event
```

### Testing with Sentry

In some cases, you may want to _test_ that certain actions in your application cause a report to be sent to Sentry. Sentry itself does this by using [Bypass]. It is important to note that when modifying the environment configuration the test case should not be run asynchronously, since you are modifying **global configuration**. Not returning the environment configuration to its original state could also affect other tests depending on how the Sentry configuration interacts with them. A good way to make sure to revert the environment is to use the [`on_exit/2`][exunit-on-exit] callback that ships with ExUnit.

For example:

```elixir
test "add/2 does not raise but sends an event to Sentry when given bad input" do
  bypass = Bypass.open()

  Bypass.expect(bypass, fn conn ->
    assert {:ok, _body, conn} = Plug.Conn.read_body(conn)
    Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
  end)

  Sentry.put_config(:dsn, "http://public:secret@localhost:#{bypass.port}/1")
  Sentry.put_config(:send_result, :sync)

  on_exit(fn ->
    Sentry.put_config(:dsn, nil)
    Sentry.put_config(:send_result, :none)
  end)

  MyModule.add(1, "a")
end
```

When testing, you will also want to set the `:send_result` type to `:sync`, so that sending Sentry events blocks until the event is sent.

## Integrations

  * [Phoenix and Plug][setup-phoenix-and-plug]

## Contributing to the SDK

Please refer to [`CONTRIBUTING.md`](CONTRIBUTING.md).

## Getting Help/Support

If you need help setting up or configuring the Python SDK (or anything else in the Sentry universe) please head over to the [Sentry Community on Discord](https://discord.com/invite/Ww9hbqr). There is a ton of great people in our Discord community ready to help you!

## Resources

  * [![Documentation](https://img.shields.io/badge/documentation-hexdocs.svg)][docs]
  * [![Forum](https://img.shields.io/badge/forum-sentry-green.svg)](https://forum.sentry.io/c/sdks)
  * [![Discord](https://img.shields.io/discord/621778831602221064)](https://discord.gg/Ww9hbqr)
  * [![Stack Overflow](https://img.shields.io/badge/stack%20overflow-sentry-green.svg)](http://stackoverflow.com/questions/tagged/sentry)
  * [![Twitter Follow](https://img.shields.io/twitter/follow/getsentry?label=getsentry&style=social)](https://twitter.com/intent/follow?screen_name=getsentry)

## License

Licensed under the MIT license, see [`LICENSE`](./LICENSE).

[Sentry]: http://sentry.io/
[Jason]: https://github.com/michalmuskala/jason
[Hackney]: https://github.com/benoitc/hackney
[Bypass]: https://github.com/PSPDFKit-labs/bypass
[docs]: https://hexdocs.pm/sentry/readme.html
[logger-handlers]: https://www.erlang.org/doc/apps/kernel/logger_chapter#handlers
[setup-phoenix-and-plug]: https://hexdocs.pm/sentry/setup-with-plug-and-phoenix.html
[exunit-on-exit]: https://hexdocs.pm/ex_unit/ExUnit.Callbacks.html#on_exit/2
