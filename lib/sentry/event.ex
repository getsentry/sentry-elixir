defmodule Sentry.Event do
  @moduledoc """
  Provides functions to create Sentry events from scratch, from exceptions, and so on.

  This module also contains the main event struct. Events are the fundamental data
  that clients send to the Sentry server.

  See <https://develop.sentry.dev/sdk/event-payloads>.
  """

  alias Sentry.{Config, Context, Interfaces, UUID}

  @sdk %Interfaces.SDK{
    name: "sentry-elixir",
    version: Mix.Project.config()[:version]
  }

  @source_files if Config.enable_source_code_context(),
                  do: Sentry.Sources.load_files(Config.root_source_code_paths()),
                  else: nil
  @deps if Config.report_deps(), do: Map.keys(Mix.Project.deps_paths()), else: []

  @typedoc """
  The level of an event.
  """
  @typedoc since: "9.0.0"
  @type level() :: :fatal | :error | :warning | :info | :debug

  @typedoc """
  The type for the event struct.

  See [`%Sentry.Event{}`](`__struct__/0`) for more information.
  """
  @type t() :: %__MODULE__{
          # Required
          event_id: <<_::256>>,
          timestamp: String.t() | number(),
          platform: :elixir,

          # Optional
          level: level() | nil,
          logger: String.t() | nil,
          transaction: String.t() | nil,
          server_name: String.t() | nil,
          release: String.t() | nil,
          dist: String.t() | nil,
          tags: %{optional(String.t()) => String.t()},
          environment: String.t() | nil,
          modules: %{optional(String.t()) => String.t()},
          extra: map(),
          fingerprint: [String.t()],

          # Interfaces.
          breadcrumbs: [Interfaces.Breadcrumb.t()],
          contexts: Interfaces.context(),
          exception: Interfaces.Exception.t() | nil,
          message: String.t() | nil,
          request: Interfaces.request(),
          sdk: Interfaces.SDK.t() | nil,
          user: Interfaces.user() | nil,

          # Non-payload fields.
          __source__: term(),
          __original_exception__: Exception.t() | nil
        }

  @doc """
  The struct representing the event.

  In general, you're not advised to manipulate this struct's fields directly. Instead,
  try to use functions such as `create_event/1` or `transform_exception/2` for creating
  events.
  """
  @enforce_keys [:event_id, :timestamp]
  defstruct [
    # Required. Hexadecimal string representing a uuid4 value. The length is exactly 32
    # characters. Dashes are not allowed. Has to be lowercase.
    :event_id,

    # Required. Indicates when the event was created in the Sentry SDK. The format is either a
    # string as defined in RFC 3339 or a numeric (integer or float) value representing the number
    # of seconds that have elapsed since the Unix epoch.
    :timestamp,

    # Optional fields without defaults.
    :level,
    :logger,
    :transaction,
    :server_name,
    :release,
    :dist,

    # Interfaces.
    :breadcrumbs,
    :contexts,
    :exception,
    :message,
    :request,
    :sdk,
    :user,

    # "Culprit" is not documented anymore and we should move to transactions at some point.
    # https://forum.sentry.io/t/culprit-deprecated-in-favor-of-what/4871/9
    :culprit,

    # Non-payload "private" fields.
    :__source__,
    :__original_exception__,

    # Required. Has to be "elixir".
    platform: :elixir,

    # Optional fields with defaults.
    tags: %{},
    modules: %{},
    extra: %{},
    fingerprint: [],
    environment: "production"
  ]

  @doc """
  Creates an event struct out of collected context and options.

  ## Options

    * `:exception` - an `t:Exception.t/0`

    * `:stacktrace` - a stacktrace, as in `t:Exception.stacktrace/0`

    * `:message` - a message (`t:String.t/0`)

    * `:extra` - map of extra context, which gets merged with the current context
      (see `Sentry.Context`)

    * `:user` - map of user context, which gets merged with the current context
      (see `Sentry.Context`)

    * `:tags` - map of tags context, which gets merged with the current context
      (see `Sentry.Context`)

    * `:request` - map of request context, which gets merged with the current context
      (see `Sentry.Context`)

    * `:breadcrumbs` - list of breadcrumbs

    * `:level` - error level (see `t:t/0`)

    * `:fingerprint` - list of the fingerprint for grouping this event (a list of `t:String.t/0`)

    * `:event_source` - the source of the event. This fills in the `:__source__` field of the
      returned struct.

  ## Examples

      iex> event = create_event(exception: %RuntimeError{message: "oops"}, level: :warning)
      iex> event.level
      :warning
      iex> event.exception.type
      "RuntimeError"

      iex> event = create_event(event_source: :plug)
      iex> event.__source__
      :plug

  """
  @spec create_event([option]) :: t()
        when option:
               {:user, Interfaces.user()}
               | {:request, Interfaces.request()}
               | {:extra, Context.extra()}
               | {:breadcrumbs, Context.breadcrumb()}
               | {:tags, Context.tags()}
               | {:level, level()}
               | {:fingerprint, [String.t()]}
               | {:message, String.t()}
               | {:event_source, term()}
               | {:exception, Exception.t()}
               | {:stacktrace, Exception.stacktrace()}
  def create_event(opts) when is_list(opts) do
    timestamp =
      DateTime.utc_now()
      |> DateTime.truncate(:microsecond)
      |> DateTime.to_iso8601()
      |> String.trim_trailing("Z")

    %{
      user: user_context,
      tags: tags_context,
      extra: extra_context,
      breadcrumbs: breadcrumbs_context,
      request: request_context
    } = Sentry.Context.get_all()

    fingerprint = Keyword.get(opts, :fingerprint, ["{{ default }}"])

    extra =
      extra_context
      |> Map.merge(Keyword.get(opts, :extra, %{}))

    user =
      user_context
      |> Map.merge(Keyword.get(opts, :user, %{}))

    tags =
      Config.tags()
      |> Map.merge(tags_context)
      |> Map.merge(Keyword.get(opts, :tags, %{}))

    request =
      request_context
      |> Map.merge(Keyword.get(opts, :request, %{}))

    breadcrumbs =
      Keyword.get(opts, :breadcrumbs, [])
      |> Kernel.++(breadcrumbs_context)
      |> Enum.take(-1 * Config.max_breadcrumbs())
      |> Enum.map(&struct(Interfaces.Breadcrumb, &1))

    message = Keyword.get(opts, :message)
    exception = Keyword.get(opts, :exception)

    %__MODULE__{
      event_id: UUID.uuid4_hex(),
      timestamp: timestamp,
      level: Keyword.get(opts, :level, :error),
      server_name: Config.server_name() || to_string(:net_adm.localhost()),
      release: Config.release(),
      sdk: @sdk,
      tags: tags,
      modules:
        Enum.reduce(@deps, %{}, fn app, acc ->
          Map.put(acc, app, to_string(Application.spec(app, :vsn)))
        end),
      culprit: culprit_from_stacktrace(Keyword.get(opts, :stacktrace, [])),
      extra: extra,
      breadcrumbs: breadcrumbs,
      contexts: generate_contexts(),
      exception: coerce_exception(exception, Keyword.get(opts, :stacktrace), message),
      message: message,
      fingerprint: fingerprint,
      environment: Config.environment_name(),
      user: user,
      request: request,
      __source__: Keyword.get(opts, :event_source),
      __original_exception__: exception
    }
  end

  defp coerce_exception(_exception = nil, _stacktrace = nil, _message) do
    nil
  end

  defp coerce_exception(_exception = nil, stacktrace_or_nil, message) when is_binary(message) do
    stacktrace =
      if is_list(stacktrace_or_nil) do
        %Interfaces.Stacktrace{frames: stacktrace_to_frames(stacktrace_or_nil)}
      end

    %Interfaces.Exception{
      type: "message",
      value: message,
      stacktrace: stacktrace
    }
  end

  defp coerce_exception(exception, stacktrace_or_nil, _message) when is_exception(exception) do
    stacktrace =
      if is_list(stacktrace_or_nil) do
        %Interfaces.Stacktrace{frames: stacktrace_to_frames(stacktrace_or_nil)}
      end

    %Interfaces.Exception{
      type: inspect(exception.__struct__),
      value: Exception.message(exception),
      stacktrace: stacktrace
    }
  end

  defp coerce_exception(_exception = nil, stacktrace, _message = nil) do
    unless is_nil(stacktrace) do
      raise ArgumentError,
            "cannot provide a :stacktrace option without an exception or a message, got: #{inspect(stacktrace)}"
    end
  end

  @doc """
  Transforms an exception to a Sentry event.

  This essentially defers to `create_event/1`, inferring some options from
  the given `exception`.

  ## Options

  This function takes the same options as `create_event/1`.
  """
  @spec transform_exception(Exception.t(), keyword()) :: t()
  def transform_exception(exception, opts) when is_exception(exception) and is_list(opts) do
    opts
    |> Keyword.put(:exception, exception)
    |> create_event()
  end

  defmacrop put_source_context_if_enabled(frame, file, line_number) do
    if Config.enable_source_code_context() do
      quote do
        do_put_source_context(unquote(frame), unquote(file), unquote(line_number))
      end
    else
      quote do
        unquote(frame)
      end
    end
  end

  @doc """
  Converts the given stacktrace to a list of Sentry stacktrace frames.

  ## Examples

      iex> stacktrace = [{URI, :default_port, [:https, 4443], [file: "uri.ex", line: 12]}]
      iex> stacktrace_to_frames(stacktrace)
      [
        %Interfaces.Stacktrace.Frame{
          module: URI,
          function: "URI.default_port/2",
          filename: "uri.ex",
          lineno: 12,
          in_app: false,
          vars: %{"arg0" => ":https", "arg1" => "4443"}
        }
      ]

  """
  @spec stacktrace_to_frames(Exception.stacktrace()) :: [Interfaces.Stacktrace.Frame.t()]
  def stacktrace_to_frames(stacktrace) when is_list(stacktrace) do
    in_app_module_allow_list = Config.in_app_module_allow_list()

    Enum.reduce(stacktrace, [], fn entry, acc ->
      [stacktrace_entry_to_frame(entry, in_app_module_allow_list) | acc]
    end)
  end

  defp stacktrace_entry_to_frame(entry, in_app_module_allow_list) do
    {module, function, location} =
      case entry do
        {mod, function, arity_or_args, location} ->
          {mod, Exception.format_mfa(mod, function, arity_to_integer(arity_or_args)), location}

        {function, arity_or_args, location} ->
          {nil, Exception.format_fa(function, arity_to_integer(arity_or_args)), location}
      end

    file =
      case Keyword.fetch(location, :file) do
        {:ok, file} when not is_nil(file) -> to_string(file)
        _other -> nil
      end

    line = location[:line]

    frame = %Interfaces.Stacktrace.Frame{
      module: module,
      function: function,
      filename: file,
      lineno: line,
      in_app: in_app?(entry, in_app_module_allow_list),
      vars: args_from_stacktrace([entry])
    }

    put_source_context_if_enabled(frame, file, line)
  end

  # There's no module here.
  defp in_app?({_function, _arity_or_args, _location}, _in_app_allow_list), do: false

  # No modules are allowed.
  defp in_app?(_stacktrace_entry, []), do: false

  defp in_app?({module, _function, _arity_or_args, _location}, in_app_module_allow_list) do
    split_module = module_split(module)

    Enum.any?(in_app_module_allow_list, fn module ->
      allowed_split_module = module_split(module)
      Enum.take(split_module, length(allowed_split_module)) == allowed_split_module
    end)
  end

  defp module_split(module) do
    module
    |> Atom.to_string()
    |> String.trim_leading("Elixir.")
    |> String.split(".")
  end

  def do_put_source_context(%Interfaces.Stacktrace.Frame{} = frame, file, line) do
    {pre_context, context, post_context} =
      Sentry.Sources.get_source_context(@source_files, file, line)

    %Interfaces.Stacktrace.Frame{
      frame
      | context_line: context,
        pre_context: pre_context,
        post_context: post_context
    }
  end

  @spec culprit_from_stacktrace(Exception.stacktrace()) :: String.t() | nil
  def culprit_from_stacktrace([]), do: nil

  def culprit_from_stacktrace([{m, f, a, _} | _]) do
    Exception.format_mfa(m, f, arity_to_integer(a))
  end

  def culprit_from_stacktrace([{m, f, a} | _]) do
    Exception.format_mfa(m, f, arity_to_integer(a))
  end

  @doc ~S"""
  Builds a map of *variables* and their values from the given stacktrace.

  For Sentry, typically the key in the map would be the name of the variable,
  but we don't have that available, so we fall back to `arg<x>` (see examples).

  ## Examples

      iex> stacktrace = [{URI, :default_port, [:https, 4443], _location = []}]
      iex> args_from_stacktrace(stacktrace)
      %{"arg0" => ":https", "arg1" => "4443"}

  """
  @spec args_from_stacktrace(Exception.stacktrace()) :: %{optional(String.t()) => String.t()}
  def args_from_stacktrace(stacktrace)

  def args_from_stacktrace([{_mod, _fun, args, _location} | _rest]) when is_list(args),
    do: stacktrace_args_to_vars(args)

  def args_from_stacktrace([{_fun, args, _location} | _rest]) when is_list(args),
    do: stacktrace_args_to_vars(args)

  def args_from_stacktrace([_other | _rest]), do: %{}

  defp stacktrace_args_to_vars(args) do
    for {arg, index} <- Enum.with_index(args), into: %{} do
      {"arg#{index}", String.slice(inspect(arg), 0, 513)}
    end
  end

  defp arity_to_integer(arity) when is_list(arity), do: Enum.count(arity)
  defp arity_to_integer(arity) when is_integer(arity), do: arity

  defp generate_contexts do
    {_, os_name} = :os.type()

    os_version =
      case :os.version() do
        {major, minor, release} -> "#{major}.#{minor}.#{release}"
        version_string -> version_string
      end

    %{
      os: %{name: Atom.to_string(os_name), version: os_version},
      runtime: %{name: "elixir", version: System.build_info().build}
    }
  end
end
