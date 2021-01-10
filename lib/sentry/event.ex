defmodule Sentry.Event do
  @moduledoc """
    Provides an Event Struct as well as transformation of Logger
    entries into Sentry Events.

  ### Configuration

  * `:in_app_module_allow_list` - Expects a list of modules that is used to distinguish among stacktrace frames that belong to your app and ones that are part of libraries or core Elixir.  This is used to better display the significant part of stacktraces.  The logic is greedy, so if your app's root module is `MyApp` and your setting is `[MyApp]`, that module as well as any submodules like `MyApp.Submodule` would be considered part of your app.  Defaults to `[]`.
  * `:report_deps` - Flag for whether to include the loaded dependencies when reporting an error. Defaults to true.

  """

  defstruct event_id: nil,
            culprit: nil,
            timestamp: nil,
            message: nil,
            tags: %{},
            level: "error",
            platform: "elixir",
            server_name: nil,
            environment: nil,
            exception: nil,
            original_exception: nil,
            release: nil,
            stacktrace: %{
              frames: []
            },
            request: %{},
            extra: %{},
            user: %{},
            breadcrumbs: [],
            fingerprint: [],
            modules: %{},
            event_source: nil

  @type sentry_exception :: %{type: String.t(), value: String.t(), module: any()}
  @type t :: %__MODULE__{
          event_id: String.t() | nil,
          culprit: String.t() | nil,
          timestamp: String.t() | nil,
          message: String.t() | nil,
          tags: map(),
          level: String.t(),
          platform: String.t(),
          server_name: any(),
          environment: any(),
          exception: [sentry_exception()],
          original_exception: Exception.t() | nil,
          release: any(),
          stacktrace: %{
            frames: [map()]
          },
          request: map(),
          extra: map(),
          user: map(),
          breadcrumbs: list(),
          fingerprint: list(),
          modules: map(),
          event_source: any()
        }

  alias Sentry.{Config, Event, Util}
  @source_code_context_enabled Config.enable_source_code_context()
  @source_files if(@source_code_context_enabled, do: Sentry.Sources.load_files(), else: nil)

  @enable_deps_reporting Config.report_deps()
  @deps if(
          @enable_deps_reporting,
          do: Util.mix_deps(),
          else: []
        )

  @doc """
  Creates an Event struct out of context collected and options
  ## Options
    * `:exception` - Sentry-structured exception
    * `:original_exception` - Original Elixir exception struct
    * `:message` - message
    * `:stacktrace` - a list of Exception.stacktrace()
    * `:extra` - map of extra context
    * `:user` - map of user context
    * `:tags` - map of tags context
    * `:request` - map of request context
    * `:breadcrumbs` - list of breadcrumbs
    * `:event_source` - the source of the event
    * `:level` - error level
    * `:fingerprint` -  list of the fingerprint for grouping this event
  """
  @spec create_event(keyword()) :: Event.t()
  def create_event(opts) do
    %{
      user: user_context,
      tags: tags_context,
      extra: extra_context,
      breadcrumbs: breadcrumbs_context,
      request: request_context
    } = Sentry.Context.get_all()

    exception = Keyword.get(opts, :exception)
    original_exception = Keyword.get(opts, :original_exception)

    message = Keyword.get(opts, :message)

    event_source = Keyword.get(opts, :event_source)

    stacktrace =
      Keyword.get(opts, :stacktrace, [])
      |> coerce_stacktrace()

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

    level = Keyword.get(opts, :level, "error")

    release = Config.release()

    server_name = Config.server_name()

    env = Config.environment_name()

    %Event{
      culprit: culprit_from_stacktrace(stacktrace),
      message: message,
      level: level,
      platform: "elixir",
      environment: env,
      server_name: server_name,
      exception: exception,
      original_exception: original_exception,
      stacktrace: %{
        frames: stacktrace_to_frames(stacktrace)
      },
      release: release,
      extra: extra,
      tags: tags,
      user: user,
      breadcrumbs: breadcrumbs,
      request: request,
      fingerprint: fingerprint,
      modules: Util.mix_deps_versions(@deps),
      event_source: event_source
    }
    |> add_metadata()
  end

  @doc """
  Transforms an Exception to a Sentry event.
  ## Options
    * `:stacktrace` - a list of Exception.stacktrace()
    * `:extra` - map of extra context
    * `:user` - map of user context
    * `:tags` - map of tags context
    * `:request` - map of request context
    * `:breadcrumbs` - list of breadcrumbs
    * `:level` - error level
    * `:fingerprint` -  list of the fingerprint for grouping this event

  """
  @spec transform_exception(Exception.t(), keyword()) :: Event.t()
  def transform_exception(%_{} = exception, opts) do
    type =
      exception.__struct__
      |> to_string()
      |> String.trim_leading("Elixir.")

    value = Exception.message(exception)

    module = Keyword.get(opts, :module)
    transformed_exception = [%{type: type, value: value, module: module}]

    message = "(#{type} #{value})"

    opts
    |> Keyword.put(:exception, transformed_exception)
    |> Keyword.put(:message, message)
    |> Keyword.put(:original_exception, exception)
    |> create_event()
  end

  @spec add_metadata(Event.t()) :: Event.t()
  def add_metadata(%Event{} = state) do
    %{state | event_id: Util.uuid4_hex(), timestamp: Util.iso8601_timestamp()}
    |> Map.update(:server_name, nil, fn server_name ->
      server_name || to_string(:net_adm.localhost())
    end)
  end

  defmacrop put_source_context(frame, file, line_number) do
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

  @spec stacktrace_to_frames(Exception.stacktrace()) :: [map]
  def stacktrace_to_frames(stacktrace) do
    in_app_module_allow_list = Config.in_app_module_allow_list()

    stacktrace
    |> Enum.map(fn line ->
      {mod, function, arity_or_args, location} = line
      f_args = args_from_stacktrace([line])
      arity = arity_to_integer(arity_or_args)
      file = Keyword.get(location, :file)
      file = if(file, do: String.Chars.to_string(file), else: file)
      line_number = Keyword.get(location, :line)

      %{
        filename: file && to_string(file),
        function: Exception.format_mfa(mod, function, arity),
        module: mod,
        lineno: line_number,
        in_app: is_in_app?(mod, in_app_module_allow_list),
        vars: f_args
      }
      |> put_source_context(file, line_number)
    end)
    |> Enum.reverse()
  end

  @spec do_put_source_context(map(), String.t(), integer()) :: map()
  def do_put_source_context(frame, file, line_number) do
    {pre_context, context, post_context} =
      Sentry.Sources.get_source_context(@source_files, file, line_number)

    frame
    |> Map.put(:context_line, context)
    |> Map.put(:pre_context, pre_context)
    |> Map.put(:post_context, post_context)
  end

  @spec culprit_from_stacktrace(Exception.stacktrace()) :: String.t() | nil
  def culprit_from_stacktrace([]), do: nil

  def culprit_from_stacktrace([{m, f, a, _} | _]) do
    Exception.format_mfa(m, f, arity_to_integer(a))
  end

  def culprit_from_stacktrace([{m, f, a} | _]) do
    Exception.format_mfa(m, f, arity_to_integer(a))
  end

  @doc """
  Builds a map from argument value list.  For Sentry, typically the
  key in the map would be the name of the variable, but we don't have that
  available.
  """
  @spec args_from_stacktrace(Exception.stacktrace()) :: map()
  def args_from_stacktrace([{_m, _f, a, _} | _]) when is_list(a) do
    Enum.with_index(a)
    |> Enum.into(%{}, fn {arg, index} ->
      {"arg#{index}", String.slice(inspect(arg, limit: 513, printable_limit: 513), 0, 513)}
    end)
  end

  def args_from_stacktrace(_), do: %{}

  defp arity_to_integer(arity) when is_list(arity), do: Enum.count(arity)
  defp arity_to_integer(arity) when is_integer(arity), do: arity

  defp is_in_app?(nil, _in_app_allow_list), do: false
  defp is_in_app?(_, []), do: false

  defp is_in_app?(module, in_app_module_allow_list) do
    split_modules = module_split(module)

    Enum.any?(in_app_module_allow_list, fn module ->
      allowed_split_modules = module_split(module)

      count = Enum.count(allowed_split_modules)
      Enum.take(split_modules, count) == allowed_split_modules
    end)
  end

  defp module_split(module) when is_binary(module) do
    String.split(module, ".")
    |> Enum.reject(&(&1 == "Elixir"))
  end

  defp module_split(module), do: module_split(String.Chars.to_string(module))

  defp coerce_stacktrace({m, f, a}), do: [{m, f, a, []}]
  defp coerce_stacktrace(stacktrace), do: stacktrace
end
