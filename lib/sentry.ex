defmodule Sentry do
  @moduledoc ~S"""
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

  The basic configuration options are:

    * `:dsn` (`t:String.t/0`) - the DSN for your Sentry project.
      If this is not set, Sentry will not be enabled. If the `SENTRY_DSN`
      environment variable is set, it will be used as the default value.

    * `:release` (`t:String.t/0`) - the release version of your application.
      This is used to correlate events with source code. If the `SENTRY_RELEASE`
      environment variable is set, it will be used as the default value.

    * `:environment_name` (`t:atom/0` or `t:String.t/0`) - the current
      environment name. This is used to determine if Sentry should be enabled
      and if events should be sent. For events to be sent, the value of
      this option must appear in the `:included_environments` list.
      If the `SENTRY_ENVIRONMENT` environment variable is set, it will
      be used as the defaults value. Otherwise, defaults to `"dev"`.

    * `:included_environments` (list of `t:atom/0` or `t:String.t/0`, or the atom `:all`) -
      the environments in which Sentry can report events. If this is a list,
      then `:environment_name` needs to be in this list for events to be reported.
      If this is `:all`, then Sentry will report events regardless of the value
      of `:environment_name`. Defaults to `:all`.

    * `:tags` (`t:map/0`) - a map of tags to be sent with every event.
      Defaults to `%{}`.

    * `:server_name` (`t:String.t/0`) - the name of the server running the
      application. Not used by default.

    * `:filter` (`t:module/0`) - a module that implements the `Sentry.Filter`
      behaviour. Defaults to `Sentry.DefaultEventFilter`. See the
      [*Filtering Exceptions* section](#module-filtering-exceptions) below.

    * `:json_library` (`t:module/0`) - a module that implements the "standard"
      Elixir JSON behaviour, that is, exports the `encode/1` and `decode/1`
      functions. Defaults to `Jason`, which requires [`:jason`](https://hex.pm/packages/jason)
      to be a dependency of your application.

    * `:log_level` (`t:Logger.level/0`) - the level to use when Sentry fails to
      send an event due to an API failure or other reasons. Defaults to `:warning`.

  To customize what happens when sending an event, you can use these options:

    * `:sample_rate` (`t:float/0` between `0.0` and `1.0`) - the percentage
      of events to send to Sentry. Defaults to `1.0` (100% of events).

    * `:send_result` (`t:atom/0`) - controls what to return when reporting exceptions
      to Sentry. Defaults to `:none`.

    * `:send_max_attempts` (`t:integer/0`) - the maximum number of attempts to
      send an event to Sentry. Defaults to `4`.

    * `:max_breadcrumbs` (`t:integer/0`) - the maximum number of breadcrumbs
      to keep. Defaults to `100`. See `Sentry.Context.add_breadcrumb/1`.

    * `:before_send_event` (`t:before_send_event_callback/0`) - allows performing operations
      on the event *before* it is sent as well as filtering out the event altogether.
      If the callback returns `nil` or `false`, the event is not reported. If it returns an
      updated `Sentry.Event`, then the updated event is used instead. See the [*Event Callbacks*
      section](#module-event-callbacks) below for more information.

    * `:after_send_event` (`t:after_send_event_callback/0`) - callback that is called *after*
      attempting to send an event. The result of the HTTP call as well as the event will
      be passed as arguments. The return value of the callback is not returned. See the
      [*Event Callbacks* section](#module-event-callbacks) below for more information.

    * `:in_app_module_allow_list` (list of `t:module/0`) - a list of modules that is used
      to distinguish among stacktrace frames that belong to your app and ones that are
      part of libraries or core Elixir. This is used to better display the significant part
      of stacktraces. The logic is "greedy", so if your app's root module is `MyApp` and
      you configure this option to `[MyApp]`, `MyApp` as well as any submodules
      (like `MyApp.Submodule`) would be considered part of your app. Defaults to `[]`.

  To customize the behaviour of the HTTP client used by Sentry, you can
  use these options:

    * `:client` (`t:module/0`) - a module that implements the `Sentry.HTTPClient`
      behaviour. Defaults to `Sentry.HackneyClient`, which uses
      [hackney](https://github.com/benoitc/hackney) as the HTTP client.

    * `:hackney_opts` (`t:keyword/0`) - options to be passed to `hackney`. Only
      applied if `:client` is set to `Sentry.HackneyClient`. Defaults to
      `[pool: :sentry_pool]`.

    * `:hackney_pool_max_connections` (`t:integer/0`) - the maximum number of
      connections to keep in the pool. Only applied if `:client` is set to
      `Sentry.HackneyClient`. Defaults to `50`.

    * `:hackney_pool_timeout` (`t:integer/0`) - the maximum time to wait for a
      connection to become available. Only applied if `:client` is set to
      `Sentry.HackneyClient`. Defaults to `5000`.

  To customize options related to reporting source code context, you can use these
  options:

    * `:report_deps` (`t:boolean/0`) - whether to report application dependencies of your
      application alongside events. This list contains applications (alongside their version)
      that are **loaded** when the `:sentry` application starts. Defaults to `true`.

    * `:enable_source_code_context` (`t:boolean/0`) - whether to report source
      code context alongside events. Defaults to `false`.

    * `:root_source_code_paths` (list of `t:Path.t/0`) - a list of paths to the root of
      your application's source code. This is used to determine the relative
      path of files in stack traces. Usually, you'll want to set this to
      `[File.cwd!()]`. For umbrella apps, you should set this to all the application
      paths in your umbrella (such as `[Path.join(File.cwd!(), "apps/app1"), ...]`).
      **Required** if `:enabled_source_code_context` is `true`.

    * `:source_code_path_pattern` (`t:String.t/0`) - a glob pattern used to
      determine which files to report source code context for. The glon "starts"
      from `:root_source_code_paths`. Defaults to `"**/*.ex"`.

    * `:source_code_exclude_patterns` (list of `t:Regex.t/0`) - a list of regular
      expressions used to determine which files to exclude from source code
      context. Defaults to `[~r"/_build/", ~r"/deps/", ~r"/priv/"]`.

    * `:context_lines` (`t:integer/0`) - the number of lines of source code
      before and after the line that caused the exception to report. Defaults to `3`.

  > #### Compile-time Configuration {: .tip}
  >
  > These options are only available at compile-time:
  >   * `:enable_source_code_context`
  >   * `:root_source_code_paths`
  >   * `:source_code_path_pattern`
  >   * `:source_code_exclude_patterns`
  >
  > If you change the value of any of these, you'll need to recompile Sentry itself.
  > You can run `mix deps.compile sentry` to do that.

  ### Configuration Through System Environment

  Sentry supports loading configuration from the system environment. You can do this
  by setting `SENTRY_<name>` environment variables. For example, to set the `:release`
  option through the system environment, you can set the `SENTRY_RELEASE` environment
  variable.

  The supported `SENTRY_<name>` environment variables are:

    * `SENTRY_RELEASE`
    * `SENTRY_ENVIRONMENT`
    * `SENTRY_DSN`

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
              Logger.info(fn -> "Did not successfully send event! #{inspect(event)}" end)
          end
        end
      end

  ## Reporting Source Code

  Sentry supports reporting the source code of (and around) the line that
  caused an issue. To support this functionality, this library stores
  the text of source files during compilation. An example configuration
  to enable this functionality is:

      config :sentry,
        dsn: "https://public:secret@app.getsentry.com/1",
        enable_source_code_context: true,
        root_source_code_paths: [File.cwd!()],
        context_lines: 5

  File contents are saved when Sentry is compiled, which can cause some
  complications. If a file is changed, and Sentry is not recompiled,
  it will still report old source code.

  The best way to ensure source code is up to date is to recompile Sentry
  itself via `mix deps.compile sentry --force`. It's possible to create a Mix
  task alias in `mix.exs` to do this. The example below would allow you to
  run `mix sentry_recompile && mix compile` which will force recompilation of Sentry so
  it has the newest source and then compile the project. The second `mix compile`
  is required due to Mix only invoking the same task once in an alias.

      defp aliases do
        [sentry_recompile: ["compile", "deps.compile sentry --force"]]
      end

  This is an important to note especially when building for production. If your
  build or deployment system caches prior builds, it may not recompile Sentry
  and could cause issues with reported source code being out of date.

  Due to Sentry reading the file system and defaulting to a recursive search
  of directories, it is important to check your configuration and compilation
  environment to avoid a folder recursion issue. Problems may be seen when
  deploying to the root folder, so it is best to follow the practice of
  compiling your application in its own folder. Modifying the
  `:source_code_path_pattern` configuration option from its default is also
  an avenue to avoid compile problems.
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

  `opts` argument is passed as the second argument to `Sentry.send_event/2`.
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

    * `:sample_rate` - The sampling factor to apply to events. A value of `0.0` will deny sending
      any events, and a value of `1.0` will send 100% of events. Sampling is applied **after**
      the `:before_send_event` callback. See where [the Sentry
      documentation](https://develop.sentry.dev/sdk/sessions/#filter-order) suggests this.

    * Other options, such as `:stacktrace` or `:extra`, will be passed to
      `Sentry.Event.create_event/1` downstream. See `Sentry.Event.create_event/1`
      for available options.

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
end
