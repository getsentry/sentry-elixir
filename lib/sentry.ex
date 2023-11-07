defmodule Sentry do
  @moduledoc """
  Provides the functionality to submit events to [Sentry](https://sentry.io).

  This library can be used to submit events to Sentry from any Elixir application.
  It supports several ways of reporting events:

    * Manually — see `capture_exception/2` and `capture_message/2`.

    * Through an Elixir `Logger` backend — see `Sentry.LoggerBackend`.

    * Automatically for Plug/Phoenix applications — see the
      [*Setup with Plug and Phoenix* guide](setup-with-plug-and-phoenix.html), and the
      `Sentry.PlugCapture` and `Sentry.PlugContext` modules.

  ## Usage

  Add the following to your production configuration:

      # In config/prod.exs
      config :sentry, dsn: "https://public:secret@app.getsentry.com/1",
        included_environments: [:prod],
        environment_name: :prod,
        tags: %{
          env: "production"
        }

  The `:environment_name` and `:included_environments` options work together to determine
  if and when Sentry should record exceptions. The `:environment_name` is the
  name of the current environment. In the example above, we have explicitly set
  the environment to `:prod` which works well if you are inside an environment
  specific configuration `config/prod.exs`.

  An alternative is to use `Config.config_env/0` in your general `config/config.exs`
  configuration file:

      config :sentry, dsn: "https://public:secret@app.getsentry.com/1",
        included_environments: [:prod],
        environment_name: config_env()

  This will set the environment name to whatever the current environment
  is, but it will only send events if the current environment is `:prod`,
  since that is the only entry in the `:included_environments` key.

  You can even rely on more specific logic to determine the environment name. It's
  not uncommon for most applications to have a "staging" environment. In order
  to handle this without adding an additional Mix environment, you can set an
  environment variable that determines the release level. By default, Sentry
  picks up the `SENTRY_ENVIRONMENT` variable. Otherwise, you can read the
  variable at runtime. Do this only in `config/runtime.exs` so that it will
  work both for local development as well as Mix releases.

      # In config/runtime.exs
      config :sentry, dsn: "https://public:secret@app.getsentry.com/1",
        included_environments: ["production", "staging"],
        environment_name: System.get_env("RELEASE_LEVEL", "development")

  In this example, we are getting the environment name from the `RELEASE_LEVEL`
  environment variable. If that variable does not exist, we default to `"development"`.
  Now, on our servers, we can set the environment variable appropriately. On
  our local development machines, exceptions will never be sent, because the
  default value is not in the list of `:included_environments`.

  > #### Using the DSN To Send Events {: .warning}
  >
  > We recommend to use the `:dsn` configuration to control whether to report
  > events. If `:dsn` is not set (or set to `nil`), then we won't report
  > events to Sentry. Thanks to this behavior, you can essentially
  > only set `:dsn` in environments where you want to report events to Sentry.
  > In the future, we might remove the `:included_environments` configuration
  > altogether.

  Sentry supports many configuration options. See the [*Configuration*
  section](#module-configuration) for complete documentation.

  ## Configuration

  You can configure Sentry through the application environment. Configure
  the following keys under the `:sentry` application. For example, you can
  do this in `config/config.exs`:

      # config/config.exs
      config :sentry,
        # ...

  **Sentry reads the configuration when the `:sentry` application starts**, and
  will not pick up any changes after that. This is in line with how other
  Sentry SDKs (and many other Erlang/Elixir libraries) work. The reason
  for this choice is performance: the SDK performs validation on application
  start and then caches the configuration (in [`:persistent_term`](`:persistent_term`)).

  > #### Updating Configuration at Runtime {: .tip}
  >
  > If you *must* update configuration at runtime, use `put_config/2`. This
  > function is not efficient (since it updates terms in `:persistent_term`),
  > but it works in a pinch. For example, it's useful if you're verifying
  > that you send the right events to Sentry in your test suite, so you need to
  > change the `:dsn` configuration to point to a local server that you can verify
  > requests on.

  Below you can find all the available configuration options.

  #{Sentry.Config.docs()}

  > #### Configuration Through System Environment {: .info}
  >
  > Sentry supports loading some configuration from the system environment.
  > The supported environment variables are: `SENTRY_RELEASE`, `SENTRY_ENVIRONMENT`,
  > and `SENTRY_DSN`. See the `:release`, `:environment_name`, and `:dsn` configuration
  > options respectively for more information.

  ## Filtering Exceptions

  If you would like to prevent Sentry from sending certain exceptions, you can
  use the `:before_send_event` configuration option. See the [*Event Callbacks*
  section](#module-event-callbacks) below.

  Before v9.0.0, the recommended way to filter out exceptions was to use a *filter*,
  that is, a module implementing the `Sentry.EventFilter` behaviour. This is still supported,
  but is not deprecated. See `Sentry.EventFilter` for more information.

  ## Event Callbacks

  You can configure the `:before_send_event` and `:after_send_event` options to
  customize what happens before and/or after sending an event. The `:before_send_event`
  callback must be of type `t:before_send_event_callback/0` and the `:after_send_event`
  callback must be of type `t:after_send_event_callback/0`. For example, you
  can set:

      config :sentry,
        before_send_event: {MyModule, :before_send},
        after_send_event: {MyModule, :after_send}

  `MyModule` could look like this:

      defmodule MyModule do
        def before_send(event) do
          metadata = Map.new(Logger.metadata())
          %Sentry.Event{event | extra: Map.merge(event.extra, metadata)}
        end

        def after_send_event(event, result) do
          case result do
            {:ok, id} ->
              Logger.info("Successfully sent event!")

            {:error, _reason} ->
              Logger.info(fn -> "Did not successfully send event! \#{inspect(event)}" end)
          end
        end
      end

  ## Reporting Source Code

  Sentry supports reporting the source code of (and around) the line that
  caused an issue. An example configuration to enable this functionality is:

      config :sentry,
        dsn: "https://public:secret@app.getsentry.com/1",
        enable_source_code_context: true,
        root_source_code_paths: [File.cwd!()],
        context_lines: 5

  To support this functionality, Sentry needs to **package** source code
  and store it so that it's available in the compiled application. Packaging source
  code is an active step you have to take; use the [`mix
  sentry.package_source_code`](`Mix.Tasks.Sentry.PackageSourceCode`) Mix task to do that.

  Sentry stores the packaged source code in its `priv` directory. This is included by
  default in [Mix releases](`Mix.Tasks.Release`). Once the source code is packaged
  and ready to ship with your release, Sentry will load it when the `:sentry` application
  starts. If there are issues with loading the packaged code, Sentry will log some warnings
  but will boot up normally and it just won't report source code context.

  > #### Prune Large File Trees {: .tip}
  >
  > Due to Sentry reading the file system and defaulting to a recursive search
  > of directories, it is important to check your configuration and compilation
  > environment to avoid a folder recursion issue. You might see problems when
  > deploying to the root folder, so it is best to follow the practice of
  > compiling your application in its own folder. Modifying the
  > `:source_code_path_pattern` configuration option from its default is also
  > an avenue to avoid compile problems, as well as pruning unnecessary files
  > with `:source_code_exclude_patterns`.
  """

  alias Sentry.{Config, Event}

  require Logger

  @typedoc """
  A callback to use with the `:before_send_event` configuration option.
  configuration options.k

  If this is `{module, function_name}`, then `module.function_name(event)` will
  be called, where `event` is of type `t:Sentry.Event.t/0`.

  See the [*Configuration* section](#module-configuration) in the module documentation
  for more information on configuration.
  """
  @typedoc since: "9.0.0"
  @type before_send_event_callback() ::
          (Sentry.Event.t() -> as_boolean(Sentry.Event.t()))
          | {module(), function_name :: atom()}

  @typedoc """
  A callback to use with the `:after_send_event` configuration option.

  If this is `{module, function_name}`, then `module.function_name(event, result)` will
  be called, where `event` is of type `t:Sentry.Event.t/0`.
  """
  @typedoc since: "9.0.0"
  @type after_send_event_callback() ::
          (Sentry.Event.t(), result :: term() -> term())
          | {module(), function_name :: atom()}

  @typedoc """
  The strategy to use when sending an event to Sentry.
  """
  @typedoc since: "9.0.0"
  @type send_type() :: :sync | :none

  @type send_result() ::
          {:ok, event_or_envelope_id :: String.t()}
          | {:error, term()}
          | :ignored
          | :unsampled
          | :excluded

  @doc """
  Parses and submits an exception to Sentry

  This only sends the exception if the current Sentry environment is in
  the `:included_environments`. See the [*Configuration* section](#module-configuration)
  in the module documentation.

  The `opts` argument is passed as the second argument to `send_event/2`.
  """
  @spec capture_exception(Exception.t(), keyword()) :: send_result
  def capture_exception(exception, opts \\ []) do
    filter_module = Config.filter()
    event_source = Keyword.get(opts, :event_source)

    if filter_module.exclude_exception?(exception, event_source) do
      :excluded
    else
      exception
      |> Event.transform_exception(opts)
      |> send_event(opts)
    end
  end

  @doc """
  Puts the last event ID sent to the server for the current process in
  the process dictionary.
  """
  @spec put_last_event_id_and_source(String.t()) :: {String.t(), atom() | nil} | nil
  def put_last_event_id_and_source(event_id, source \\ nil) when is_binary(event_id) do
    Process.put(:sentry_last_event_id_and_source, {event_id, source})
  end

  @doc """
  Gets the last event ID sent to the server from the process dictionary.
  Since it uses the process dictionary, it will only return the last event
  ID sent within the current process.
  """
  @spec get_last_event_id_and_source() :: {String.t(), atom() | nil} | nil
  def get_last_event_id_and_source do
    Process.get(:sentry_last_event_id_and_source)
  end

  @doc """
  Reports a message to Sentry.

  `opts` argument is passed as the second argument to `send_event/2`.
  """
  @spec capture_message(String.t(), keyword()) :: send_result
  def capture_message(message, opts \\ []) when is_binary(message) do
    opts
    |> Keyword.put(:message, message)
    |> Event.create_event()
    |> send_event(opts)
  end

  @doc """
  Sends an event to Sentry.

  An **event** is the most generic payload you can send to Sentry. It encapsulates
  information about an exception, a message, or any other event that you want to
  report. To manually build events, see the functions in `Sentry.Event`.

  ## Options

  The supported options are:

    * `:result` - Allows specifying how the result should be returned. The possible values are:

      * `:sync` - Sentry will make an API call synchronously (including retries) and will
        return `{:ok, event_id}` if successful.

      * `:none` - Sentry will send the event in the background, in a *fire-and-forget*
        fashion. The function will return `{:ok, ""}` regardless of whether the API
        call ends up being successful or not.

      * `:async` - **Not supported anymore**, see the information below.

    * `:sample_rate` - same as the global `:sample_rate` configuration, but applied only to
      this call. See the module documentation. *Available since v10.0.0*.

    * `:before_send_event` - same as the global `:before_send_event` configuration, but
      applied only to this call. See the module documentation. *Available since v10.0.0*.

    * `:after_send_event` - same as the global `:after_send_event` configuration, but
      applied only to this call. See the module documentation. *Available since v10.0.0*.

    * `:client` - same as the global `:client` configuration, but
      applied only to this call. See the module documentation. *Available since v10.0.0*.

  > #### Async Send {: .error}
  >
  > Before v9.0.0 of this library, the `:result` option also supported the `:async` value.
  > This would spawn a `Task` to make the API call, and would return a `{:ok, Task.t()}` tuple.
  > You could use `Task` operations to wait for the result asynchronously. Since v9.0.0, this
  > option is not present anymore. Instead, you can spawn a task yourself that then calls this
  > function with `result: :sync`. The effect is exactly the same.

  > #### Sending Exceptions and Messages {: .tip}
  >
  > This function is **low-level**, and mostly intended for library developers,
  > or folks that want to have full control on what they report to Sentry. For most
  > use cases, use `capture_exception/2` or `capture_message/2`.
  """
  @spec send_event(Event.t(), keyword()) :: send_result
  def send_event(event, opts \\ [])

  def send_event(%Event{message: nil, exception: []}, _opts) do
    Logger.log(Config.log_level(), "Sentry: unable to parse exception")

    :ignored
  end

  def send_event(%Event{} = event, opts) do
    included_environments = Config.included_environments()
    environment_name = to_string(Config.environment_name())

    if included_environments == :all or environment_name in included_environments do
      Sentry.Client.send_event(event, opts)
    else
      :ignored
    end
  end

  @doc ~S"""
  Updates the value of `key` in the configuration *at runtime*.

  Once the `:sentry` application starts, it validates and caches the value of the
  configuration options you start it with. Because of this, updating configuration
  at runtime requires this function as opposed to just changing the application
  environment.

  > #### This Function Is Slow {: .warning}
  >
  > This function updates terms in [`:persistent_term`](`:persistent_term`), which is what
  > this SDK uses to cache configuration. Updating terms in `:persistent_term` is slow
  > and can trigger full GC sweeps. We recommend only using this function in rare cases,
  > or during tests.

  ## Examples

  For example, if you're using [`Bypass`](https://github.com/PSPDFKit-labs/bypass) to test
  that you send the correct events to Sentry:

      test "reports the correct event to Sentry" do
        bypass = Bypass.open()

        Bypass.expect(...)

        Sentry.put_config(:dsn, "http://public:secret@localhost:#{bypass.port}/1")
        Sentry.put_config(:send_result, :sync)

        my_function_to_test()
      end

  """
  @doc since: "10.0.0"
  @spec put_config(atom(), term()) :: :ok
  defdelegate put_config(key, value), to: Config
end
