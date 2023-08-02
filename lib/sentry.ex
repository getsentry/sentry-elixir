defmodule Sentry do
  use Application
  alias Sentry.{Config, Event}
  require Logger

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
  if and when Sentry should record exceptions. The `en:vironment_name` is the
  name of the current environment. In the example above, we have explicitly set
  the environment to `:prod` which works well if you are inside an environment
  specific configuration `config/prod.exs`.

  An alternative is to use `Config.config_env/0` in your general configuration file:

      config :sentry, dsn: "https://public:secret@app.getsentry.com/1",
        included_environments: [:prod],
        environment_name: config_env()

  This will set the environment name to whatever the current environment
  is, but it will only send events if the current environment is `:prod`,
  since that is the only entry in the `:included_environments` key.

  You can even rely on more specific logic to determine the environment name. It's
  not uncommmon for most applications to have a "staging" environment. In order
  to handle this without adding an additional Mix environment, you can set an
  environment variable that determines the release level. By default, Sentry
  picks up the `SENTRY_ENVIRONMENT` variable. Otherwise, you can read the
  variable at runtime. Do this only in `config/runtime.exs` so that it will
  work both for local development as well as Mix releases.

      # In config/runtime.exs
      config :sentry, dsn: "https://public:secret@app.getsentry.com/1",
        included_environments: ~w(production staging),
        environment_name: System.get_env("RELEASE_LEVEL", "development")

  In this example, we are getting the environment name from the `RELEASE_LEVEL`
  environment variable. If that variable does not exist, we default to `"development"`.
  Now, on our servers, we can set the environment variable appropriately. On
  our local development machines, exceptions will never be sent, because the
  default value is not in the list of `:included_environments`.

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

    * `:included_environments` (list of `t:atom/0` or `t:String.t/0`) -
      the environments in which Sentry can report events. `:environment_name`
      needs to be in this list for events to be reported. Defaults to `[:prod]`.

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
      on the event *before* it is sent. If the callback returns `nil` or `false`,
      the event is not reported. If it returns an updated `Sentry.Event`, then
      the updated event is used instead. See the [*Event Callbacks*
      section](#module-event-callbacks) below for more information.

    * `:after_send_event` (`t:after_send_event_callback/0`) - callback that is called *after*
      attempting to send an event.  The result of the HTTP call as well as the event will
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

    * `:report_deps` (`t:boolean/0`) - whether to report Mix dependencies of your
      application alongside events. If `true`, this attempts to load dependencies
      *at compile time*. Defaults to `true`.

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
  >   * `:report_deps`
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

  You can also load configuration at runtime via `{:system, "SYSTEM_ENV_KEY"}` tuples,
  where Sentry will read `SYSTEM_ENV_KEY` to get the config value from the system
  environment at runtime.

  The supported `SENTRY_<name>` environment variables are:

    * `SENTRY_RELEASE`
    * `SENTRY_ENVIRONMENT_NAME`
    * `SENTRY_DSN`

  ## Filtering Exceptions

  If you would like to prevent Sentry from sending certain exceptions, you can
  use the `:filter` configuration option. It must be configured to be a module
  that implements the `Sentry.EventFilter` behaviour.

  A configuration like the one below prevents sending `Phoenix.Router.NoRouteError`
  exceptions coming from `Sentry.Plug`, but allows other exceptions to be sent.

      defmodule MyApp.SentryEventFilter do
        @behaviour Sentry.EventFilter

        @impl true
        def exclude_exception?(%Phoenix.Router.NoRouteError{}, :plug), do: true
        def exclude_exception?(_exception, _source), do: false
      end

      # In config/config.exs
      config :sentry,
        filter: MyApp.SentryEventFilter,
        # other config...


  ## Event Callbacks

  You can configure the `:before_send_event` and `:after_send_event` options to
  customize what happens before and/or after sending an event. For example, you
  can set:

      config :sentry,
        before_send_event: {MyModule, :before_send},
        before_send_event: {MyModule, :after_send}

  `MyModule` could look like this:

      defmodule MyModule do
        def before_send(event) do
          metadata = Map.new(Logger.metadata())
          %{event | extra: Map.merge(event.extra, metadata)}
        end

        def after_send_event(event, result) do
          case result do
            {:ok, id} ->
              Logger.info("Successfully sent event!")

            _ ->
              Logger.info(fn -> "Did not successfully send event! #{inspect(event)}" end)
          end
        end
      end

  """

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

  @type send_result :: Sentry.Client.send_event_result() | :excluded | :ignored

  def start(_type, _opts) do
    children = [
      {Task.Supervisor, name: Sentry.TaskSupervisor},
      Config.client().child_spec()
    ]

    if Config.client() == Sentry.HackneyClient do
      unless Code.ensure_loaded?(:hackney) do
        raise """
        cannot start the :sentry application because the HTTP client is set to \
        Sentry.HackneyClient (which is the default), but the Hackney library is not loaded. \
        Add :hackney to your dependencies to fix this.
        """
      end

      case Application.ensure_all_started(:hackney) do
        {:ok, _apps} -> :ok
        {:error, reason} -> raise "failed to start the :hackney application: #{inspect(reason)}"
      end
    end

    Config.warn_for_deprecated_env_vars!()
    validate_json_config!()
    Config.validate_log_level!()
    Config.validate_included_environments!()
    Config.assert_dsn_has_no_query_params!()

    opts = [strategy: :one_for_one, name: Sentry.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @doc """
  Parses and submits an exception to Sentry

  This only sends the exception if the current Sentry environment is in
  the `:included_environments`. See the [*Configuration* section](#module-configuration)
  in the module documentation.

  The `opts` argument is passed as the second argument to `send_event/2`.
  """
  @spec capture_exception(Exception.t(), Keyword.t()) :: send_result
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
  @spec capture_message(String.t(), Keyword.t()) :: send_result
  def capture_message(message, opts \\ []) when is_binary(message) do
    opts
    |> Keyword.put(:message, message)
    |> Event.create_event()
    |> send_event(opts)
  end

  @doc """
  Sends a `Sentry.Event`

  `opts` argument is passed as the second argument to `send_event/2` of the configured `Sentry.HTTPClient`.  See `Sentry.Client.send_event/2` for more information.
  """
  @spec send_event(Event.t(), Keyword.t()) :: send_result
  def send_event(event, opts \\ [])

  def send_event(%Event{message: nil, exception: nil}, _opts) do
    Logger.log(Config.log_level(), "Sentry: unable to parse exception")

    :ignored
  end

  def send_event(%Event{} = event, opts) do
    included_environments = Config.included_environments()
    environment_name = Config.environment_name()

    if environment_name in included_environments do
      Sentry.Client.send_event(event, opts)
    else
      :ignored
    end
  end

  defp validate_json_config!() do
    case Config.json_library() do
      nil ->
        raise ArgumentError.exception("nil is not a valid :json_library configuration")

      library ->
        try do
          with {:ok, %{}} <- library.decode("{}"),
               {:ok, "{}"} <- library.encode(%{}) do
            :ok
          else
            _ ->
              raise ArgumentError.exception(
                      "configured :json_library #{inspect(library)} does not implement decode/1 and encode/1"
                    )
          end
        rescue
          UndefinedFunctionError ->
            reraise ArgumentError.exception("""
                    configured :json_library #{inspect(library)} is not available or does not implement decode/1 and encode/1.
                    Do you need to add #{inspect(library)} to your mix.exs?
                    """),
                    __STACKTRACE__
        end
    end
  end
end
