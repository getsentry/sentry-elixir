defmodule Sentry.Event do
  @moduledoc """
  Provides functions to create Sentry events from scratch, from exceptions, and so on.

  This module also contains the main event struct. Events are the fundamental data
  that clients send to the Sentry server.

  See <https://develop.sentry.dev/sdk/event-payloads>.
  """

  alias Sentry.{Attachment, Config, Interfaces, Sources, UUID}

  @sdk %Interfaces.SDK{
    name: "sentry-elixir",
    version: Mix.Project.config()[:version]
  }

  @typedoc """
  The level of an event.
  """
  @typedoc since: "9.0.0"
  @type level() :: :fatal | :error | :warning | :info | :debug

  @typedoc """
  The type for the event struct.

  All of the fields in this struct map directly to the fields described in the
  [Sentry documentation](https://develop.sentry.dev/sdk/event-payloads). These fields
  are the exceptions, and are specific to the Elixir Sentry SDK:

    * `:source` - the source of the event. `Sentry.LoggerBackend` and `Sentry.LoggerHandler`
      set this to `:logger`, while `Sentry.PlugCapture` and `Sentry.PlugContext` set it to
      `:plug`. You can set it to any atom. See the `:event_source` option in `create_event/1`
      and `transform_exception/2`.

    * `:original_exception` - the original exception that is being reported, if there's one.
      The Elixir Sentry SDK manipulates reported exceptions to make them fit the payload
      required by the Sentry API, and these end up in the `:exception` field. The
      `:original_exception` field, instead, contains the original exception as the raw Elixir
      term (such as `%RuntimeError{...}`).

  See also [`%Sentry.Event{}`](`__struct__/0`).
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
          exception: [Interfaces.Exception.t()],
          message: Interfaces.Message.t() | nil,
          request: Interfaces.Request.t() | nil,
          sdk: Interfaces.SDK.t() | nil,
          threads: [Interfaces.Thread.t()] | nil,
          user: Interfaces.user() | nil,

          # Non-payload fields.
          source: atom(),
          original_exception: Exception.t() | nil,
          attachments: [Attachment.t()]
        }

  @doc """
  The struct representing the event.

  You're not advised to manipulate this struct's fields directly. Instead,
  use functions such as `create_event/1` or `transform_exception/2` for creating
  events.

  See the `t:t/0` type for information on the fields and their types.
  """
  @enforce_keys [:event_id, :timestamp]
  defstruct [
    # Required. Hexadecimal string representing a uuid4 value. The length is exactly 32
    # characters. Dashes are not allowed. Has to be lowercase.
    event_id: nil,

    # Required. Indicates when the event was created in the Sentry SDK. The format is either a
    # string as defined in RFC 3339 or a numeric (integer or float) value representing the number
    # of seconds that have elapsed since the Unix epoch.
    timestamp: nil,

    # Optional fields.
    breadcrumbs: [],
    contexts: nil,
    dist: nil,
    environment: "production",
    exception: [],
    extra: %{},
    fingerprint: [],
    level: nil,
    logger: nil,
    message: nil,
    modules: %{},
    platform: :elixir,
    release: nil,
    request: %Interfaces.Request{},
    sdk: nil,
    server_name: nil,
    tags: %{},
    transaction: nil,
    threads: nil,
    user: %{},

    # "Culprit" is not documented anymore and we should move to transactions at some point.
    # https://forum.sentry.io/t/culprit-deprecated-in-favor-of-what/4871/9
    culprit: nil,

    # Non-payload "private" fields.
    attachments: [],
    source: nil,
    original_exception: nil
  ]

  # Removes all the non-payload keys from the event so that the client can render
  @doc false
  @spec remove_non_payload_keys(t()) :: map()
  def remove_non_payload_keys(%__MODULE__{} = event) do
    event
    |> Map.from_struct()
    |> Map.drop([:original_exception, :source, :attachments])
  end

  create_event_opts_schema = [
    exception: [
      type: {:custom, __MODULE__, :__validate_exception__, [:exception]},
      type_doc: "`t:Exception.t/0`",
      doc: """
      This is the exception that gets reported in the
      `:exception` field of `t:t/0`. The term passed here also ends up unchanged in the
      `:original_exception` field of `t:t/0`. This option is **required** unless the
      `:message` option is present. Not present by default.
      """
    ],
    stacktrace: [
      type:
        {:list,
         {:or,
          [
            {:tuple, [:atom, :atom, :any, :keyword_list]},
            {:tuple, [:any, :any, :keyword_list]}
          ]}},
      type_doc: "`t:Exception.stacktrace/0`",
      doc: """
      The exception's stacktrace. This can also be used with messages (`:message`). Not
      present by default.
      """
    ],
    message: [
      type: :string,
      doc: """
      A message to report. The string can contain interpolation markers (`%s`). In that
      case, you can pass the `:interpolation_parameters` option as well to fill
      in those parameters. See `Sentry.capture_message/2` for more information on
      message interpolation. Not present by default.
      """
    ],
    extra: [
      type: {:map, {:or, [:atom, :string]}, :any},
      type_doc: "`t:Sentry.Context.extra/0`",
      default: %{},
      doc: """
      Map of extra context, which gets merged with the current context
      (see `Sentry.Context.set_extra_context/1`). If fields collide, the ones
      in the map passed through this option have precedence over the ones in
      the context.
      """
    ],
    user: [
      type: :map,
      type_doc: "`t:Sentry.Context.user_context/0`",
      default: %{},
      doc: """
      Map of user context, which gets merged with the current context
      (see `Sentry.Context.set_user_context/1`). If fields collide, the ones
      in the map passed through this option have precedence over the ones in
      the context.
      """
    ],
    tags: [
      type: {:map, {:or, [:atom, :string]}, :any},
      type_doc: "`t:Sentry.Context.tags/0`",
      default: %{},
      doc: """
      Map of tags context, which gets merged with the current context (see
      `Sentry.Context.set_tags_context/1`) and with the `:tags` option in the global
      Sentry configuration. If fields collide, the ones in the map passed through
      this option have precedence over the ones in the context, which have precedence
      over the ones in the configuration.
      """
    ],
    request: [
      type: :map,
      type_doc: "`t:Sentry.Context.request_context/0`",
      default: %{},
      doc: """
      Map of request context, which gets merged with the current context
      (see `Sentry.Context.set_request_context/1`). If fields collide, the ones
      in the map passed through this option have precedence over the ones in
      the context.
      """
    ],
    breadcrumbs: [
      type: {:list, {:or, [:keyword_list, :map]}},
      type_doc: "list of `t:keyword/0` or `t:Sentry.Context.breadcrumb/0`",
      default: [],
      doc: """
      List of breadcrumbs. This list gets **prepended** to the list
      in the context (see `Sentry.Context.add_breadcrumb/1`).
      """
    ],
    level: [
      type: {:in, [:fatal, :error, :warning, :info, :debug]},
      type_doc: "`t:level/0`",
      default: :error,
      doc: """
      The level of the event.
      """
    ],
    fingerprint: [
      type: {:list, :string},
      default: ["{{ default }}"],
      doc: """
      List of the fingerprint for grouping this event.
      """
    ],
    event_source: [
      type: :atom,
      doc: """
      The source of the event. This fills in the `:source` field of the
      returned struct. This is not present by default.
      """
    ],
    interpolation_parameters: [
      type: {:list, :any},
      doc: """
      The parameters to use for message interpolation. This is only used if the
      `:message` option is present. This is not present by default. See
      `Sentry.capture_message/2`. *Available since v10.1.0*.
      """
    ],

    ## Internal options
    handled: [
      type: :boolean,
      default: true,
      doc: false
    ]
  ]

  @create_event_opts_schema NimbleOptions.new!(create_event_opts_schema)

  @doc """
  Creates an event struct out of collected context and options.

  > #### Merging Options with Context and Config {: .info}
  >
  > Some of the options documented below are **merged** with the Sentry context, or
  > with the Sentry context *and* the configuration. The option you pass here always
  > has higher precedence, followed by the context and finally by the configuration.
  >
  > See also `Sentry.Context` for information on the Sentry context and `Sentry` for
  > information on configuration.

  ## Options

  #{NimbleOptions.docs(@create_event_opts_schema)}

  ## Examples

      iex> event = create_event(exception: %RuntimeError{message: "oops"}, level: :warning)
      iex> event.level
      :warning
      iex> hd(event.exception).type
      "RuntimeError"
      iex> event.original_exception
      %RuntimeError{message: "oops"}

      iex> event = create_event(message: "Unknown route", event_source: :plug)
      iex> event.source
      :plug

  """
  @spec create_event([option]) :: t()
        when option: unquote(NimbleOptions.option_typespec(@create_event_opts_schema))
  def create_event(opts) when is_list(opts) do
    opts = NimbleOptions.validate!(opts, @create_event_opts_schema)

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
      request: request_context,
      attachments: attachments_context
    } = Sentry.Context.get_all()

    extra = Map.merge(extra_context, Keyword.fetch!(opts, :extra))
    user = Map.merge(user_context, Keyword.fetch!(opts, :user))
    request = Map.merge(request_context, Keyword.fetch!(opts, :request))

    tags =
      Config.tags()
      |> Map.merge(tags_context)
      |> Map.merge(Keyword.fetch!(opts, :tags))

    breadcrumbs =
      opts
      |> Keyword.fetch!(:breadcrumbs)
      |> Kernel.++(breadcrumbs_context)
      |> Enum.take(-1 * Config.max_breadcrumbs())
      |> Enum.map(&struct(Interfaces.Breadcrumb, &1))

    message = Keyword.get(opts, :message)
    exception = Keyword.get(opts, :exception)
    stacktrace = Keyword.get(opts, :stacktrace)
    source = Keyword.get(opts, :event_source)
    handled? = Keyword.fetch!(opts, :handled)

    event = %__MODULE__{
      attachments: attachments_context,
      breadcrumbs: breadcrumbs,
      contexts: generate_contexts(),
      culprit: culprit_from_stacktrace(Keyword.get(opts, :stacktrace, [])),
      environment: Config.environment_name(),
      event_id: UUID.uuid4_hex(),
      exception: List.wrap(coerce_exception(exception, stacktrace, message, handled?)),
      extra: extra,
      fingerprint: Keyword.fetch!(opts, :fingerprint),
      level: Keyword.fetch!(opts, :level),
      message: message && build_message_interface(message, opts),
      modules: :persistent_term.get({:sentry, :loaded_applications}),
      original_exception: exception,
      release: Config.release(),
      request: struct(%Interfaces.Request{}, request),
      sdk: @sdk,
      server_name: Config.server_name() || to_string(:net_adm.localhost()),
      source: source,
      tags: tags,
      timestamp: timestamp,
      user: user
    }

    # If we have a message *and* a stacktrace, but no exception, we need to store the stacktrace
    # information within a "thread" interface. This is how the Python SDK also does it. An issue
    # was opened in the sentry-elixir repo about this, but this is also a Sentry issue (if there
    # is an exception of type "message" with a stacktrace *and* a "message" attribute, it should
    # still show properly). This issue is now tracked in Sentry itself:
    # https://github.com/getsentry/sentry/issues/61239
    if message && stacktrace && is_nil(exception) do
      add_thread_with_stacktrace(event, stacktrace)
    else
      event
    end
  end

  defp build_message_interface(raw_message, opts) do
    if params = Keyword.get(opts, :interpolation_parameters) do
      %Interfaces.Message{
        formatted: interpolate(raw_message, params),
        message: raw_message,
        params: params
      }
    else
      %Interfaces.Message{formatted: raw_message}
    end
  end

  # Made public for testing.
  @doc false
  def interpolate(message, params) do
    parts = Regex.split(~r{%s}, message, include_captures: true, trim: true)

    {iodata, _params} =
      Enum.reduce(parts, {"", params}, fn
        "%s", {acc, [param | rest_params]} ->
          {[acc, to_string(param)], rest_params}

        "%s", {acc, []} ->
          {[acc, "%s"], []}

        part, {acc, params} ->
          {[acc, part], params}
      end)

    IO.iodata_to_binary(iodata)
  end

  # If we have a message with a stacktrace, but no exceptions, for now we store the stacktrace in
  # the "threads" interface and we don't fill in the "exception" interface altogether. This might
  # be eventually fixed in Sentry itself: https://github.com/getsentry/sentry/issues/61239
  defp coerce_exception(_exception = nil, _stacktrace_or_nil, message, _handled?)
       when is_binary(message) do
    nil
  end

  defp coerce_exception(exception, stacktrace_or_nil, _message, handled?)
       when is_exception(exception) do
    %Interfaces.Exception{
      type: inspect(exception.__struct__),
      value: Exception.message(exception),
      stacktrace: coerce_stacktrace(stacktrace_or_nil),
      mechanism: %Interfaces.Exception.Mechanism{handled: handled?}
    }
  end

  defp coerce_exception(_exception = nil, stacktrace, _message = nil, _handled?) do
    unless is_nil(stacktrace) do
      raise ArgumentError,
            "cannot provide a :stacktrace option without an exception or a message, got: #{inspect(stacktrace)}"
    end
  end

  defp add_thread_with_stacktrace(%__MODULE__{} = event, stacktrace) when is_list(stacktrace) do
    thread = %Interfaces.Thread{
      id: UUID.uuid4_hex(),
      stacktrace: coerce_stacktrace(stacktrace)
    }

    %__MODULE__{event | threads: [thread]}
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

  defp coerce_stacktrace(nil) do
    nil
  end

  defp coerce_stacktrace(stacktrace) when is_list(stacktrace) do
    case stacktrace_to_frames(stacktrace) do
      [] -> nil
      frames -> %Interfaces.Stacktrace{frames: frames}
    end
  end

  defp stacktrace_to_frames(stacktrace) when is_list(stacktrace) do
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

    maybe_put_source_context(frame, file, line)
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

  defp maybe_put_source_context(%Interfaces.Stacktrace.Frame{} = frame, file, line) do
    cond do
      not Config.enable_source_code_context?() ->
        frame

      source_map = Sources.get_source_code_map_from_persistent_term() ->
        {pre_context, context, post_context} = Sources.get_source_context(source_map, file, line)

        %Interfaces.Stacktrace.Frame{
          frame
          | context_line: context,
            pre_context: pre_context,
            post_context: post_context
        }

      true ->
        frame
    end
  end

  defp culprit_from_stacktrace([]), do: nil

  defp culprit_from_stacktrace([{m, f, a, _} | _]) do
    Exception.format_mfa(m, f, arity_to_integer(a))
  end

  defp culprit_from_stacktrace([{m, f, a} | _]) do
    Exception.format_mfa(m, f, arity_to_integer(a))
  end

  defp args_from_stacktrace([{_mod, _fun, args, _location} | _rest]) when is_list(args),
    do: stacktrace_args_to_vars(args)

  defp args_from_stacktrace([{_fun, args, _location} | _rest]) when is_list(args),
    do: stacktrace_args_to_vars(args)

  defp args_from_stacktrace([_other | _rest]), do: %{}

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

  # Used to compare events for deduplication. See "Sentry.Dedupe".
  @doc false
  @spec hash(t()) :: non_neg_integer()
  def hash(%__MODULE__{} = event) do
    :erlang.phash2([
      event.exception,
      event.message,
      event.level,
      event.fingerprint
    ])
  end

  @doc false
  def __validate_exception__(term, key) do
    if is_exception(term) do
      {:ok, term}
    else
      {:error, "expected #{inspect(key)} to be an exception, got: #{inspect(term)}"}
    end
  end
end
