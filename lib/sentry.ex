defmodule Sentry do
  @moduledoc """
  Provides the functionality to submit events to [Sentry](https://sentry.io).

  This library can be used to submit events to Sentry from any Elixir application.
  It supports several ways of reporting events:

    * Manually — see `capture_exception/2` and `capture_message/2`.

    * Through an [Erlang `:logger`](https://www.erlang.org/doc/man/logger) handler —
      see `Sentry.LoggerHandler`.

    * Through an Elixir `Logger` backend — see `Sentry.LoggerBackend`.

    * Automatically for Plug/Phoenix applications — see the
      [*Setup with Plug and Phoenix* guide](setup-with-plug-and-phoenix.html), and the
      `Sentry.PlugCapture` and `Sentry.PlugContext` modules.

  ## Usage

  Add the following to your production configuration:

      # In config/prod.exs
      config :sentry, dsn: "https://public:secret@app.getsentry.com/1",
        environment_name: :prod,
        tags: %{
          env: "production"
        }

  Sentry uses the `:dsn` option to determine whether it should record exceptions. If
  `:dsn` is set, then Sentry records exceptions. If it's not set or set to `nil`,
  then simply no events are sent to Sentry.

  > #### Included Environments {: .warning}
  >
  > Before v10.0.0, the recommended way to control whether to report events to Sentry
  > was the `:included_environments` option (a list of environments to report events for).
  > This was used together with the `:environment_name` option to determine whether to
  > send events. `:included_environments` is deprecated in v10.0.0 in favor of setting
  > or not setting `:dsn`. It will be removed in v11.0.0.

  You can even rely on more specific logic to determine the environment name. It's
  not uncommon for most applications to have a "staging" environment. In order
  to handle this without adding an additional Mix environment, you can set an
  environment variable that determines the release level. By default, Sentry
  picks up the `SENTRY_ENVIRONMENT` variable (*at runtime, when starging*).
  Otherwise, you can read the variable at runtime. Do this only in
  `config/runtime.exs` so that it will work both for local development as well
  as Mix releases.

      # In config/runtime.exs
      if config_env() == :prod do
        config :sentry, dsn: "https://public:secret@app.getsentry.com/1",
          environment_name: System.fetch_env!("RELEASE_LEVEL")
      end

  In this example, we are getting the environment name from the `RELEASE_LEVEL`
  environment variable. Now, on our servers, we can set the environment variable
  appropriately. The `config_env() == :prod` check ensures that we only set
  `:dsn` in production, effectively only enabling reporting in production-like
  environments.

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
  use the `:before_send` configuration option. See the [*Event Callbacks*
  section](#module-event-callbacks) below.

  Before v9.0.0, the recommended way to filter out exceptions was to use a *filter*,
  that is, a module implementing the `Sentry.EventFilter` behaviour. This is still supported,
  but is not deprecated. See `Sentry.EventFilter` for more information.

  ## Event Callbacks

  You can configure the `:before_send` and `:after_send_event` options to
  customize what happens before and/or after sending an event. The `:before_send`
  callback must be of type `t:before_send_event_callback/0` and the `:after_send_event`
  callback must be of type `t:after_send_event_callback/0`. For example, you
  can set:

      config :sentry,
        before_send: {MyModule, :before_send},
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

  alias Sentry.{CheckIn, Client, Config, Event, LoggerUtils}

  require Logger

  @typedoc """
  A callback to use with the `:before_send` configuration option.
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
  Parses and submits an exception to Sentry.

  This only sends the exception if the `:dsn` configuration option is set
  and is not `nil`. See the [*Configuration* section](#module-configuration)
  in the module documentation.

  The `opts` argument is passed as the second argument to `send_event/2`.
  """
  @spec capture_exception(Exception.t(), keyword()) :: send_result
  def capture_exception(exception, opts \\ []) do
    filter_module = Config.filter()
    event_source = Keyword.get(opts, :event_source)
    {send_opts, create_event_opts} = Client.split_send_event_opts(opts)

    if filter_module.exclude_exception?(exception, event_source) do
      :excluded
    else
      exception
      |> Event.transform_exception(create_event_opts)
      |> send_event(send_opts)
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

  ## Interpolation (since v10.1.0)

  The `message` argument supports interpolation. You can pass a string with formatting
  markers as `%s`, ant then pass in the `:interpolation_parameters` option as a list
  of positional parameters to interpolate. For example:

      Sentry.capture_message("Error with user %s", interpolation_parameters: ["John"])

  This way, Sentry will group the messages based on the non-interpolated string, but it
  will show the interpolated string in the UI.

  > #### Missing or Extra Parameters {: .neutral}
  >
  > If the message string has more `%s` markers than parameters, the extra `%s` markers
  > are included as is and the SDK doesn't raise any error. If you pass in more interpolation
  > parameters than `%s` markers, the extra parameters are ignored as well. This is because
  > the SDK doesn't want to be the cause of even more errors in your application when what
  > you're trying to do is report an error in the first place.
  """
  @spec capture_message(String.t(), keyword()) :: send_result
  def capture_message(message, opts \\ []) when is_binary(message) do
    {send_opts, create_event_opts} =
      opts
      |> Keyword.put(:message, message)
      |> Client.split_send_event_opts()

    event = Event.create_event(create_event_opts)
    send_event(event, send_opts)
  end

  @doc """
  Sends an event to Sentry.

  An **event** is the most generic payload you can send to Sentry. It encapsulates
  information about an exception, a message, or any other event that you want to
  report. To manually build events, see the functions in `Sentry.Event`.

  ## Options

  #{NimbleOptions.docs(Client.send_events_opts_schema())}

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
  def send_event(event, opts \\ []) do
    # TODO: remove on v11.0.0, :included_environments was deprecated in 10.0.0.
    included_envs = Config.included_environments()

    cond do
      is_nil(event.message) and event.exception == [] ->
        LoggerUtils.log("Cannot report event without message or exception: #{inspect(event)}")
        :ignored

      # If we're in test mode, let's send the event down the pipeline anyway.
      Config.test_mode?() ->
        Client.send_event(event, opts)

      !Config.dsn() ->
        :ignored

      included_envs == :all or to_string(Config.environment_name()) in included_envs ->
        Client.send_event(event, opts)

      true ->
        :ignored
    end
  end

  @doc """
  Captures a check-in built with the given `options`.

  Check-ins are used to report the status of a monitor to Sentry. This is used
  to track the health and progress of **cron jobs**. This function is somewhat
  low level, and mostly useful when you want to report the status of a cron
  but you are not using any common library to manage your cron jobs.

  This function performs a *synchronous* HTTP request to Sentry. If the request
  performs successfully, it returns `{:ok, check_in_id}` where `check_in_id` is
  the ID of the check-in that was sent to Sentry. You can use this ID to send
  updates about the same check-in. If the request fails, it returns
  `{:error, reason}`.

  > #### Setting the DSN {: .warning}
  >
  > If the `:dsn` configuration is not set, this function won't report the check-in
  > to Sentry and will instead return `:ignored`. This behaviour is consistent with
  > the rest of the SDK (such as `capture_exception/2`).

  ## Options

  This functions supports all the options mentioned in `Sentry.CheckIn.new/1`.

  ## Examples

  Say you have a GenServer which periodically sends a message to itself to execute some
  job. You could monitor the health of this GenServer by reporting a check-in to Sentry.

  For example:

      @impl GenServer
      def handle_info(:execute_periodic_job, state) do
        # Report that the job started.
        {:ok, check_in_id} = Sentry.capture_check_in(status: :in_progress, monitor_slug: "genserver-job")

        :ok = do_job(state)

        # Report that the job ended successfully.
        Sentry.capture_check_in(check_in_id: check_in_id, status: :ok, monitor_slug: "genserver-job")

        {:noreply, state}
      end

  """
  @doc since: "10.2.0"
  @spec capture_check_in(keyword()) ::
          {:ok, check_in_id :: String.t()} | :ignored | {:error, term()}
  def capture_check_in(options) when is_list(options) do
    if Config.dsn() do
      options
      |> CheckIn.new()
      |> Client.send_check_in(options)
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

  @doc """
  Returns the currently-set Sentry DSN, *if set* (or `nil` otherwise).

  This is useful in situations like capturing user feedback.
  """
  @doc since: "10.6.0"
  @spec get_dsn() :: String.t() | nil
  def get_dsn do
    case Config.dsn() do
      %Sentry.DSN{original_dsn: original_dsn} -> original_dsn
      nil -> nil
    end
  end
end
