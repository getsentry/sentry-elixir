defmodule Sentry.Config do
  @moduledoc false

  integrations_schema = [
    oban: [
      type: :keyword_list,
      doc: """
      Configuration for the [Oban](https://github.com/sorentwo/oban) integration. The Oban
      integration requires at minumum Oban Pro v0.14 or Oban v.2.17.6. *Available
      since v10.2.0*.
      """,
      keys: [
        capture_errors: [
          type: :boolean,
          default: false,
          doc: """
          Whether to capture errors from Oban jobs. When enabled, the Sentry SDK will capture
          errors that happen in Oban jobs, including when errors return `{:error, reason}`
          tuples. *Available since 10.3.0*.
          """
        ],
        cron: [
          doc: """
          Configuration options for configuring [*crons*](https://docs.sentry.io/product/crons/)
          for Oban.
          """,
          type: :keyword_list,
          keys: [
            enabled: [
              type: :boolean,
              default: false,
              doc: """
              Whether to enable the Oban integration. When enabled, the Sentry SDK will
              capture check-ins for Oban jobs. *Available since v10.2.0*.
              """
            ]
          ]
        ]
      ]
    ],
    quantum: [
      type: :keyword_list,
      doc: """
      Configuration for the [Quantum](https://github.com/quantum-elixir/quantum-core) integration.
      *Available since v10.2.0*.
      """,
      keys: [
        cron: [
          doc: """
          Configuration options for configuring [*crons*](https://docs.sentry.io/product/crons/)
          for Quantum.
          """,
          type: :keyword_list,
          keys: [
            enabled: [
              type: :boolean,
              default: false,
              doc: """
              Whether to enable the Quantum integration. When enabled, the Sentry SDK will
              capture check-ins for Quantum jobs. *Available since v10.2.0*.
              """
            ]
          ]
        ]
      ]
    ]
  ]

  basic_opts_schema = [
    dsn: [
      type: {:or, [nil, {:custom, Sentry.DSN, :parse, []}]},
      default: nil,
      type_doc: "`t:String.t/0` or `nil`",
      doc: """
      The DSN for your Sentry project. If this is not set, Sentry will not be enabled.
      If the `SENTRY_DSN` environment variable is set, it will be used as the default value.
      If `:test_mode` is `true`, the `:dsn` option is sometimes ignored; see `Sentry.Test`
      for more information.
      """
    ],
    environment_name: [
      type: {:or, [:string, :atom]},
      type_doc: "`t:String.t/0` or `t:atom/0`",
      default: "production",
      doc: """
      The current environment name. This is used to specify the environment
      that an event happened in. It can be any string shorter than 64 bytes,
      except the string `"None"`. When Sentry receives an event with an environment,
      it creates that environment if it doesn't exist yet.
      If the `SENTRY_ENVIRONMENT` environment variable is set, it will
      be used as the value for this option.
      """
    ],
    included_environments: [
      type: {:or, [{:in, [:all]}, {:list, {:or, [:atom, :string]}}]},
      deprecated: "Use :dsn to control whether to send events to Sentry.",
      type_doc: "list of `t:atom/0` or `t:String.t/0`, or the atom `:all`",
      doc: """
      **Deprecated**. The environments in which Sentry can report events. If this is a list,
      then `:environment_name` needs to be in this list for events to be reported.
      If this is `:all`, then Sentry will report events regardless of the value
      of `:environment_name`. *This will be removed in v11.0.0*.
      """
    ],
    release: [
      type: {:or, [:string, nil]},
      default: nil,
      type_doc: "`t:String.t/0` or `nil`",
      doc: """
      The release version of your application.
      This is used to correlate events with source code. If the `SENTRY_RELEASE`
      environment variable is set, it will be used as the default value.
      """
    ],
    json_library: [
      type: {:custom, __MODULE__, :__validate_json_library__, []},
      default: Jason,
      type_doc: "`t:module/0`",
      doc: """
      A module that implements the "standard" Elixir JSON behaviour, that is, exports the
      `encode/1` and `decode/1` functions. If you use the default, make sure to add
      [`:jason`](https://hex.pm/packages/jason) as a dependency of your application.
      """
    ],
    server_name: [
      type: :string,
      doc: """
      The name of the server running the application. Not used by default.
      """
    ],
    sample_rate: [
      type: {:custom, __MODULE__, :__validate_sample_rate__, []},
      default: 1.0,
      type_doc: "`t:float/0`",
      doc: """
      The percentage of events to send to Sentry. A value of `0.0` will deny sending any events,
      and a value of `1.0` will send 100% of events. Sampling is applied
      **after** the `:before_send` callback. See where [the Sentry
      documentation](https://develop.sentry.dev/sdk/sessions/#filter-order)
      suggests this. Must be between `0.0` and `1.0` (included).
      """
    ],
    tags: [
      type: {:map, :any, :any},
      default: %{},
      doc: """
      A map of tags to be sent with every event.
      """
    ],
    max_breadcrumbs: [
      type: :non_neg_integer,
      default: 100,
      doc: """
      The maximum number of breadcrumbs to keep. See `Sentry.Context.add_breadcrumb/1`.
      """
    ],
    report_deps: [
      type: :boolean,
      default: true,
      doc: """
      Whether to report application dependencies of your application
      alongside events. This list contains applications (alongside their version)
      that are **loaded** when the `:sentry` application starts.
      """
    ],
    log_level: [
      type: {:in, [:debug, :info, :warning, :warn, :error]},
      default: :warning,
      doc: """
      The level to use when Sentry fails to
      send an event due to an API failure or other reasons.
      """
    ],
    in_app_module_allow_list: [
      type: {:list, :atom},
      default: [],
      type_doc: "list of `t:module/0`",
      doc: """
      A list of modules that is used
      to distinguish among stacktrace frames that belong to your app and ones that are
      part of libraries or core Elixir. This is used to better display the significant part
      of stacktraces. The logic is "greedy", so if your app's root module is `MyApp` and
      you configure this option to `[MyApp]`, `MyApp` as well as any submodules
      (like `MyApp.Submodule`) would be considered part of your app. Defaults to `[]`.
      """
    ],
    filter: [
      type: :atom,
      type_doc: "`t:module/0`",
      default: Sentry.DefaultEventFilter,
      doc: """
      A module that implements the `Sentry.EventFilter`
      behaviour. Defaults to `Sentry.DefaultEventFilter`. See the
      [*Filtering Exceptions* section](#module-filtering-exceptions) below.
      """
    ],
    dedup_events: [
      type: :boolean,
      default: true,
      doc: """
      Whether to **deduplicate** events before reporting them to Sentry. If this option is `true`,
      then the SDK will store reported events for around 30 seconds after they're reported.
      Any time the SDK is about to report an event, it will check if it has already reported
      within the past 30 seconds. If it has, then it will not report the event again, and will
      log a message instead. Events are deduplicated by comparing their message, exception,
      stacktrace, and fingerprint. *Available since v10.0.0*.
      """
    ],
    test_mode: [
      type: :boolean,
      default: false,
      doc: """
      Whether to enable *test mode*. When test mode is enabled, the SDK will check whether
      there is a process **collecting events** and avoid sending those events if that's the
      case. This is useful for testing—see `Sentry.Test`. `:test_mode` works in tandem
      with `:dsn`; this is described in detail in `Sentry.Test`.
      """
    ],
    integrations: [
      type: :keyword_list,
      doc: """
      Configuration for integrations with third-party libraries. Every integration has its own
      option and corresponding configuration options.
      """,
      default: [],
      keys: integrations_schema
    ]
  ]

  transport_opts_schema = [
    send_result: [
      type: {:in, [:none, :sync]},
      default: :none,
      type_doc: "`t:send_type/0`",
      doc: """
      Controls what to return when reporting exceptions to Sentry.
      """
    ],
    client: [
      type: :atom,
      type_doc: "`t:module/0`",
      default: Sentry.HackneyClient,
      doc: """
      A module that implements the `Sentry.HTTPClient`
      behaviour. Defaults to `Sentry.HackneyClient`, which uses
      [hackney](https://github.com/benoitc/hackney) as the HTTP client.
      """
    ],
    send_max_attempts: [
      type: :pos_integer,
      default: 4,
      doc: """
      The maximum number of attempts to send an event to Sentry.
      """
    ],
    hackney_opts: [
      type: :keyword_list,
      default: [pool: :sentry_pool],
      doc: """
      Options to be passed to `hackney`. Only
      applied if `:client` is set to `Sentry.HackneyClient`.
      """
    ],
    hackney_pool_timeout: [
      type: :timeout,
      default: 5000,
      doc: """
      The maximum time to wait for a
      connection to become available. Only applied if `:client` is set to
      `Sentry.HackneyClient`.
      """
    ],
    hackney_pool_max_connections: [
      type: :pos_integer,
      default: 50,
      doc: """
      The maximum number of
      connections to keep in the pool. Only applied if `:client` is set to
      `Sentry.HackneyClient`.
      """
    ]
  ]

  source_code_context_opts_schema = [
    enable_source_code_context: [
      type: :boolean,
      default: false,
      doc: """
      Whether to report source code context alongside events.
      """
    ],
    root_source_code_paths: [
      type: {:list, :string},
      default: [],
      type_doc: "list of `t:Path.t/0`",
      doc: """
      Aa list of paths to the root of
      your application's source code. This is used to determine the relative
      path of files in stack traces. Usually, you'll want to set this to
      `[File.cwd!()]`. For umbrella apps, you should set this to all the application
      paths in your umbrella (such as `[Path.join(File.cwd!(), "apps/app1"), ...]`).
      **Required** if `:enabled_source_code_context` is `true`.
      """
    ],
    source_code_path_pattern: [
      type: :string,
      default: "**/*.ex",
      doc: """
      A glob pattern used to
      determine which files to report source code context for. The glob "starts"
      from `:root_source_code_paths`.
      """
    ],
    source_code_exclude_patterns: [
      type:
        {:list,
         {:custom, __MODULE__, :__validate_struct__, [:source_code_exclude_patterns, Regex]}},
      default: [~r"/_build/", ~r"/deps/", ~r"/priv/", ~r"/test/"],
      type_doc: "list of `t:Regex.t/0`",
      doc: """
      A list of regular expressions used to determine which files to
      exclude from source code context.
      """
    ],
    source_code_map_path: [
      type: :string,
      type_doc: "`t:Path.t/0`",
      doc: """
      The path to the source code map file. See
      [`mix sentry.package_source_code`](`Mix.Tasks.Sentry.PackageSourceCode`).
      Defaults to a private path inside Sentry's `priv` directory. *Available since v10.2.0*.
      """
    ],
    context_lines: [
      type: :pos_integer,
      default: 3,
      doc: """
      The number of lines of source code
      before and after the line that caused the exception to report.
      """
    ]
  ]

  hook_opts_schema = [
    before_send: [
      type: {:or, [{:fun, 1}, {:tuple, [:atom, :atom]}]},
      type_doc: "`t:before_send_event_callback/0`",
      doc: """
      Allows performing operations on the event *before* it is sent as
      well as filtering out the event altogether.
      If the callback returns `nil` or `false`, the event is not reported. If it returns an
      updated `Sentry.Event`, then the updated event is used instead. See the [*Event Callbacks*
      section](#module-event-callbacks) below for more information.

      `:before_send` is available *since v10.0.0*. Before, it was called `:before_send_event`.
      """
    ],
    before_send_event: [
      type: {:or, [{:fun, 1}, {:tuple, [:atom, :atom]}]},
      type_doc: "`t:before_send_event_callback/0`",
      deprecated: "Use :before_send instead.",
      doc: """
      Exactly the same as `:before_send`, but has been **deprecated since v10.0.0**.
      """
    ],
    after_send_event: [
      type: {:or, [{:fun, 2}, {:tuple, [:atom, :atom]}]},
      type_doc: "`t:after_send_event_callback/0`",
      doc: """
      Callback that is called *after*
      attempting to send an event. The result of the HTTP call as well as the event will
      be passed as arguments. The return value of the callback is not returned. See the
      [*Event Callbacks* section](#module-event-callbacks) below for more information.
      """
    ]
  ]

  @basic_opts_schema NimbleOptions.new!(basic_opts_schema)
  @transport_opts_schema NimbleOptions.new!(transport_opts_schema)
  @source_code_context_opts_schema NimbleOptions.new!(source_code_context_opts_schema)
  @hook_opts_schema NimbleOptions.new!(hook_opts_schema)

  @raw_opts_schema Enum.concat([
                     basic_opts_schema,
                     transport_opts_schema,
                     source_code_context_opts_schema,
                     hook_opts_schema
                   ])

  @opts_schema NimbleOptions.new!(@raw_opts_schema)
  @valid_keys Keyword.keys(@raw_opts_schema)

  @spec validate!() :: keyword()
  def validate! do
    :sentry
    |> Application.get_all_env()
    |> validate!()
  end

  @spec validate!(keyword()) :: keyword()
  def validate!(config) when is_list(config) do
    config_opts =
      config
      |> Keyword.take(@valid_keys)
      |> fill_in_from_env(:dsn, "SENTRY_DSN")
      |> fill_in_from_env(:release, "SENTRY_RELEASE")
      |> fill_in_from_env(:environment_name, "SENTRY_ENVIRONMENT")

    case NimbleOptions.validate(config_opts, @opts_schema) do
      {:ok, opts} ->
        opts
        |> normalize_included_environments()
        |> normalize_environment()
        |> handle_deprecated_before_send()

      {:error, error} ->
        raise ArgumentError, """
        invalid configuration for the :sentry application, so we cannot start or update
        its configuration. The error was:

            #{Exception.message(error)}

        See the documentation for the Sentry module for more information on configuration.
        """
    end
  end

  @spec persist(keyword()) :: :ok
  def persist(config) when is_list(config) do
    Enum.each(config, fn {key, value} ->
      :persistent_term.put({:sentry_config, key}, value)
    end)
  end

  @spec docs() :: String.t()
  def docs do
    """
    #### Basic Options

    #{NimbleOptions.docs(@basic_opts_schema)}

    #### Hook Options

    These options control hooks that this SDK can call before or after sending events.

    #{NimbleOptions.docs(@hook_opts_schema)}

    #### Transport Options

    These options control how this Sentry SDK sends events to the Sentry server.

    #{NimbleOptions.docs(@transport_opts_schema)}

    #### Source Code Context Options

    These options control how source code context is reported alongside events.

    #{NimbleOptions.docs(@source_code_context_opts_schema)}
    """
  end

  @spec dsn() :: nil | Sentry.DSN.t()
  def dsn, do: get(:dsn)

  # TODO: remove me on v11.0.0, :included_environments has been deprecated
  # in v10.0.0.
  @spec included_environments() :: :all | [String.t()]
  def included_environments, do: fetch!(:included_environments)

  @spec environment_name() :: String.t() | nil
  def environment_name, do: fetch!(:environment_name)

  @spec max_hackney_connections() :: pos_integer()
  def max_hackney_connections, do: fetch!(:hackney_pool_max_connections)

  @spec hackney_timeout() :: timeout()
  def hackney_timeout, do: fetch!(:hackney_pool_timeout)

  @spec tags() :: map()
  def tags, do: fetch!(:tags)

  @spec release() :: String.t() | nil
  def release, do: get(:release)

  @spec server_name() :: String.t() | nil
  def server_name, do: get(:server_name)

  @spec source_code_map_path() :: Path.t() | nil
  def source_code_map_path, do: get(:source_code_map_path)

  @spec filter() :: module()
  def filter, do: fetch!(:filter)

  @spec client() :: module()
  def client, do: fetch!(:client)

  @spec enable_source_code_context?() :: boolean()
  def enable_source_code_context?, do: fetch!(:enable_source_code_context)

  @spec context_lines() :: pos_integer()
  def context_lines, do: fetch!(:context_lines)

  @spec in_app_module_allow_list() :: [atom()]
  def in_app_module_allow_list, do: fetch!(:in_app_module_allow_list)

  @spec send_result() :: :none | :sync
  def send_result, do: fetch!(:send_result)

  @spec send_max_attempts() :: pos_integer()
  def send_max_attempts, do: fetch!(:send_max_attempts)

  @spec sample_rate() :: float()
  def sample_rate, do: fetch!(:sample_rate)

  @spec hackney_opts() :: keyword()
  def hackney_opts, do: fetch!(:hackney_opts)

  @spec before_send() :: (Sentry.Event.t() -> Sentry.Event.t()) | {module(), atom()} | nil
  def before_send, do: get(:before_send)

  @spec after_send_event() ::
          (Sentry.Event.t(), term() -> Sentry.Event.t()) | {module(), atom()} | nil
  def after_send_event, do: get(:after_send_event)

  @spec report_deps?() :: boolean()
  def report_deps?, do: fetch!(:report_deps)

  @spec json_library() :: module()
  def json_library, do: fetch!(:json_library)

  @spec log_level() :: :debug | :info | :warning | :warn | :error
  def log_level, do: fetch!(:log_level)

  @spec max_breadcrumbs() :: non_neg_integer()
  def max_breadcrumbs, do: fetch!(:max_breadcrumbs)

  @spec dedup_events?() :: boolean()
  def dedup_events?, do: fetch!(:dedup_events)

  @spec test_mode?() :: boolean()
  def test_mode?, do: fetch!(:test_mode)

  @spec put_config(atom(), term()) :: :ok
  def put_config(key, value) when is_atom(key) do
    unless key in @valid_keys do
      raise ArgumentError, "unknown option #{inspect(key)}"
    end

    renamed_key =
      case key do
        :before_send_event -> :before_send
        other -> other
      end

    [{key, value}]
    |> validate!()
    |> Keyword.take([renamed_key])
    |> persist()
  end

  ## Helpers

  defp fill_in_from_env(config, key, system_key) do
    Keyword.put_new_lazy(config, key, fn -> System.get_env(system_key, nil) end)
  end

  # TODO: remove me on v11.0.0, :included_environments has been deprecated
  # in v10.0.0.
  defp normalize_included_environments(config) do
    Keyword.update(config, :included_environments, :all, fn
      :all -> :all
      envs when is_list(envs) -> Enum.map(envs, &to_string/1)
    end)
  end

  # TODO: remove me on v11.0.0, :included_environments has been deprecated
  # in v10.0.0.
  defp handle_deprecated_before_send(opts) do
    {before_send_event, opts} = Keyword.pop(opts, :before_send_event)

    case Keyword.fetch(opts, :before_send) do
      {:ok, _before_send} when not is_nil(before_send_event) ->
        raise ArgumentError, """
        you cannot configure both :before_send and :before_send_event. :before_send_event
        is deprecated, so only use :before_send from now on.
        """

      {:ok, _before_send} ->
        opts

      :error when not is_nil(before_send_event) ->
        Keyword.put(opts, :before_send, before_send_event)

      :error ->
        opts
    end
  end

  defp normalize_environment(config) do
    Keyword.update!(config, :environment_name, &to_string/1)
  end

  @compile {:inline, fetch!: 1}
  defp fetch!(key) do
    :persistent_term.get({:sentry_config, key})
  rescue
    ArgumentError ->
      raise """
      the Sentry configuration seems to be not available (while trying to fetch \
      #{inspect(key)}). This is likely because the :sentry application has not been started yet. \
      Make sure that you start the :sentry application before using any of its functions.
      """
  end

  @compile {:inline, fetch!: 1}
  defp get(key) do
    :persistent_term.get({:sentry_config, key}, nil)
  end

  def __validate_path__(nil), do: {:ok, nil}

  def __validate_path__(path) when is_binary(path) do
    if File.exists?(path) do
      {:ok, path}
    else
      {:error, "path does not exist"}
    end
  end

  def __validate_sample_rate__(float) do
    if is_float(float) and float >= 0.0 and float <= 1.0 do
      {:ok, float}
    else
      {:error,
       "expected :sample_rate to be a float between 0.0 and 1.0 (included), got: #{inspect(float)}"}
    end
  end

  def __validate_json_library__(nil) do
    {:error, "nil is not a valid value for the :json_library option"}
  end

  def __validate_json_library__(mod) when is_atom(mod) do
    try do
      with {:ok, %{}} <- mod.decode("{}"),
           {:ok, "{}"} <- mod.encode(%{}) do
        {:ok, mod}
      else
        _ ->
          {:error,
           "configured :json_library #{inspect(mod)} does not implement decode/1 and encode/1"}
      end
    rescue
      UndefinedFunctionError ->
        {:error,
         """
         configured :json_library #{inspect(mod)} is not available or does not implement decode/1 and encode/1.
         Do you need to add #{inspect(mod)} to your mix.exs?
         """}
    end
  end

  def __validate_json_library__(other) do
    {:error, "expected :json_library to be a module, got: #{inspect(other)}"}
  end

  def __validate_struct__(term, key, mod) do
    if is_struct(term, mod) do
      {:ok, term}
    else
      {:error, "expected #{inspect(key)} to be a #{inspect(mod)} struct, got: #{inspect(term)}"}
    end
  end
end
