defmodule Sentry.Config do
  @moduledoc false

  @default_exclude_patterns [~r"/_build/", ~r"/deps/", ~r"/priv/", ~r"/test/"]
  @private_env_keys [:sender_pool_size]

  basic_opts_schema = [
    dsn: [
      type: {:or, [:string, nil]},
      default: nil,
      type_doc: "`t:String.t/0` or `nil`",
      doc: """
      The DSN for your Sentry project. If this is not set, Sentry will not be enabled.
      If the `SENTRY_DSN` environment variable is set, it will be used as the default value.
      """
    ],
    environment_name: [
      type: {:or, [:string, :atom]},
      type_doc: "`t:String.t/0` or `t:atom/0`",
      doc: """
      The current environment name. This is used to determine if Sentry should
      be enabled and if events should be sent. For events to be sent, the value of
      this option must appear in the `:included_environments` list.
      If the `SENTRY_ENVIRONMENT` environment variable is set, it will
      be used as the defaults value. Otherwise, defaults to `"production"`.
      """
    ],
    included_environments: [
      type: {:or, [{:in, [:all]}, {:list, {:or, [:atom, :string]}}]},
      default: :all,
      type_doc: "list of `t:atom/0` or `t:String.t/0`, or the atom `:all`",
      doc: """
      The environments in which Sentry can report events. If this is a list,
      then `:environment_name` needs to be in this list for events to be reported.
      If this is `:all`, then Sentry will report events regardless of the value
      of `:environment_name`
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
      **after** the `:before_send_event` callback. See where [the Sentry
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
      default: Sentry.DefaultEventFilter,
      doc: """
      behaviour. Defaults to `Sentry.DefaultEventFilter`. See the
      [*Filtering Exceptions* section](#module-filtering-exceptions) below.
      """
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
      default: @default_exclude_patterns,
      type_doc: "list of `t:Regex.t/0`",
      doc: """
      A list of regular expressions used to determine which files to
      exclude from source code context.
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
    before_send_event: [
      type: {:custom, __MODULE__, :__validate_hook__, [_arity = 1, :before_send_event]},
      type_doc: "`t:before_send_event_callback/0`",
      doc: """
      Allows performing operations on the event *before* it is sent as
      well as filtering out the event altogether.
      If the callback returns `nil` or `false`, the event is not reported. If it returns an
      updated `Sentry.Event`, then the updated event is used instead. See the [*Event Callbacks*
      section](#module-event-callbacks) below for more information.
      """
    ],
    after_send_event: [
      type: {:custom, __MODULE__, :__validate_hook__, [_arity = 2, :after_send_event]},
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
      |> Keyword.drop(@private_env_keys)
      |> Keyword.take(@valid_keys)
      |> fill_in_from_env(:dsn, "SENTRY_DSN")
      |> fill_in_from_env(:release, "SENTRY_RELEASE")
      |> fill_in_from_env(:environment_name, "SENTRY_ENVIRONMENT")

    case NimbleOptions.validate(config_opts, @opts_schema) do
      {:ok, opts} ->
        opts
        |> Keyword.put_new(:environment_name, "production")
        |> normalize_included_environments()
        |> normalize_environment()
        |> assert_dsn_has_no_query_params!()

      {:error, error} ->
        raise ArgumentError, """
        invalid configuration for the :sentry application, so we cannot start it. The error was:

            #{Exception.message(error)}

        See the documentation for the Sentry module for more information on configuration.
        """
    end
  end

  @spec persist(keyword()) :: :ok
  def persist(config) when is_list(config) do
    for {key, value} <- config do
      :persistent_term.put({:sentry_config, key}, value)
    end

    :ok
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

  # Also exposed as a function to be used in docs in the Sentry module.
  @spec default_source_code_exclude_patterns() :: [Regex.t(), ...]
  def default_source_code_exclude_patterns, do: @default_exclude_patterns

  @spec dsn() :: String.t() | nil
  def dsn, do: get(:dsn)

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

  @spec filter() :: module()
  def filter, do: fetch!(:filter)

  @spec client() :: module()
  def client, do: fetch!(:client)

  @spec enable_source_code_context?() :: boolean()
  def enable_source_code_context?, do: fetch!(:enable_source_code_context)

  @spec root_source_code_paths() :: [Path.t()]
  def root_source_code_paths, do: fetch!(:root_source_code_paths)

  @spec source_code_path_pattern() :: String.t()
  def source_code_path_pattern, do: fetch!(:source_code_path_pattern)

  @spec source_code_exclude_patterns() :: [Regex.t()]
  def source_code_exclude_patterns, do: fetch!(:source_code_exclude_patterns)

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

  @spec before_send_event() :: (Sentry.Event.t() -> Sentry.Event.t()) | {module(), atom()} | nil
  def before_send_event, do: get(:before_send_event)

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

  @spec put_config(atom(), term()) :: :ok
  def put_config(key, value) when is_atom(key) do
    case NimbleOptions.validate([{key, value}], @opts_schema) do
      {:ok, options} ->
        options |> Keyword.take([key]) |> persist()

      {:error, error} ->
        raise ArgumentError, """
        invalid configuration to update. The error was:

            #{Exception.message(error)}

        """
    end
  end

  ## Helpers

  defp fill_in_from_env(config, key, system_key) do
    Keyword.put_new_lazy(config, key, fn -> System.get_env(system_key, nil) end)
  end

  defp normalize_included_environments(config) do
    Keyword.update!(config, :included_environments, fn
      :all -> :all
      envs when is_list(envs) -> Enum.map(envs, &to_string/1)
    end)
  end

  defp normalize_environment(config) do
    Keyword.update!(config, :environment_name, &to_string/1)
  end

  defp assert_dsn_has_no_query_params!(config) do
    if sentry_dsn = Keyword.get(config, :dsn) do
      uri_dsn = URI.parse(sentry_dsn)

      if uri_dsn.query do
        raise ArgumentError, """
        using a Sentry DSN with query parameters is not supported since v9.0.0 of this library.
        The configured DSN was:

            #{inspect(sentry_dsn)}

        The query string in that DSN is:

            #{inspect(uri_dsn.query)}

        Please remove the query parameters from your DSN and pass them in as regular
        configuration. Check out the guide to upgrade to 9.0.0 at:

          https://hexdocs.pm/sentry/upgrade-9.x.html

        See the documentation for the Sentry module for more information on configuration
        in general.
        """
      end
    end

    config
  end

  @compile {:inline, fetch!: 1}
  defp fetch!(key) do
    :persistent_term.get({:sentry_config, key})
  end

  @compile {:inline, fetch!: 1}
  defp get(key) do
    :persistent_term.get({:sentry_config, key}, nil)
  end

  def __validate_sample_rate__(float) do
    if is_float(float) and float >= 0.0 and float <= 1.0 do
      {:ok, float}
    else
      {:error,
       "expected :sample_rate to be a float between 0.0 and 1.0 (included), got: #{inspect(float)}"}
    end
  end

  def __validate_hook__({mod, fun} = hook, _arity, _name) when is_atom(mod) and is_atom(fun) do
    {:ok, hook}
  end

  def __validate_hook__(fun, arity, name) do
    cond do
      is_function(fun, arity) ->
        {:ok, fun}

      is_function(fun) ->
        {:arity, actual} = Function.info(fun, :arity)

        {:error,
         "expected #{inspect(name)} to be an anonymous function of arity #{arity}, but got one of arity #{actual}"}

      true ->
        {:error,
         "expected #{inspect(name)} to be a {mod, fun} tuple or an anonymous function, got: #{inspect(fun)}"}
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
