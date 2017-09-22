defmodule Sentry.Event do
  @moduledoc """
    Provides an Event Struct as well as transformation of Logger
    entries into Sentry Events.


  ### Configuration

  * `:in_app_module_whitelist` - Expects a list of modules that is used to distinguish among stacktrace frames that belong to your app and ones that are part of libraries or core Elixir.  This is used to better display the significant part of stacktraces.  The logic is greedy, so if your app's root module is `MyApp` and your setting is `[MyApp]`, that module as well as any submodules like `MyApp.Submodule` would be considered part of your app.  Defaults to `[]`.
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
            release: nil,
            stacktrace: %{
              frames: []
            },
            request: %{},
            extra: %{},
            user: %{},
            breadcrumbs: [],
            fingerprint: [],
            modules: %{}

  @type t :: %__MODULE__{}

  alias Sentry.{Event, Util, Config}
  @source_code_context_enabled Config.enable_source_code_context()
  @source_files if(@source_code_context_enabled, do: Sentry.Sources.load_files(), else: nil)

  @enable_deps_reporting Config.report_deps()
  @deps if(@enable_deps_reporting, do: Util.mix_deps_to_map(Mix.Dep.loaded([env: Mix.env])), else: %{})

  @doc """
  Creates an Event struct out of context collected and options
  ## Options
    * `:exception` - expection
    * `:message` - message
    * `:stacktrace` - a list of Exception.stacktrace()
    * `:extra` - map of extra context
    * `:user` - map of user context
    * `:tags` - map of tags context
    * `:request` - map of request context
    * `:breadcrumbs` - list of breadcrumbs
    * `:level` - error level
    * `:fingerprint` -  list of the fingerprint for grouping this event
  """
  @spec create_event(keyword()) :: Event.t
  def create_event(opts) do
    %{user: user_context,
      tags: tags_context,
      extra: extra_context,
      breadcrumbs: breadcrumbs_context,
      request: request_context} = Sentry.Context.get_all()

    exception = Keyword.get(opts, :exception)

    message = Keyword.get(opts, :message)

    stacktrace = Keyword.get(opts, :stacktrace, [])

    fingerprint = Keyword.get(opts, :fingerprint, ["{{ default }}"])

    extra = extra_context
            |> Map.merge(Keyword.get(opts, :extra, %{}))
    user = user_context
           |> Map.merge(Keyword.get(opts, :user, %{}))
    tags = Config.tags()
           |> Map.merge(tags_context)
           |> Map.merge(Keyword.get(opts, :tags, %{}))
    request = request_context
              |> Map.merge(Keyword.get(opts, :request, %{}))
    breadcrumbs = Keyword.get(opts, :breadcrumbs, []) ++ breadcrumbs_context

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
      stacktrace: %{
        frames: stacktrace_to_frames(stacktrace),
      },
      release: release,
      extra: extra,
      tags: tags,
      user: user,
      breadcrumbs: breadcrumbs,
      request: request,
      fingerprint: fingerprint,
      modules: @deps,
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
  @spec transform_exception(Exception.t, keyword()) :: Event.t
  def transform_exception(exception, opts) do
    error_type = Keyword.get(opts, :error_type) || :error
    normalized = Exception.normalize(:error, exception)

    type = if(error_type == :error) do
      normalized.__struct__
    else
      error_type
    end

    value = if(error_type == :error) do
      Exception.message(normalized)
    else
      Exception.format_banner(error_type, exception)
    end

    module = Keyword.get(opts, :module)
    exception = [%{type: type, value: value, module: module}]
    message = :error
              |> Exception.format_banner(normalized)
              |> String.trim("*")
              |> String.trim()

    opts
    |> Keyword.put(:exception, exception)
    |> Keyword.put(:message, message)
    |> create_event()
  end

  @spec add_metadata(Event.t) :: Event.t
  def add_metadata(%Event{} = state) do
    %{state |
      event_id: UUID.uuid4(:hex),
      timestamp: Util.iso8601_timestamp(),
    }
    |> Map.update(:server_name, nil, fn(server_name) -> server_name || to_string(:net_adm.localhost) end)
  end

  @spec stacktrace_to_frames(Exception.stacktrace) :: [map]
  def stacktrace_to_frames(stacktrace) do
    in_app_module_whitelist = Config.in_app_module_whitelist()
    stacktrace
    |> Enum.map(fn(line) ->
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
          in_app: is_in_app?(mod, in_app_module_whitelist),
          vars: f_args,
        }
        |> put_source_context(file, line_number)
      end)
    |> Enum.reverse()
  end

  @spec put_source_context(map(), String.t, integer()) :: map()
  def put_source_context(frame, file, line_number) do
    if(@source_code_context_enabled) do
      {pre_context, context, post_context} = Sentry.Sources.get_source_context(@source_files, file, line_number)
      Map.put(frame, :context_line, context)
      |> Map.put(:pre_context, pre_context)
      |> Map.put(:post_context, post_context)
    else
      frame
    end
  end

  @spec culprit_from_stacktrace(Exception.stacktrace) :: String.t | nil
  def culprit_from_stacktrace([]), do: nil
  def culprit_from_stacktrace([{m, f, a, _} | _]) do
    Exception.format_mfa(m, f, arity_to_integer(a))
  end

  @doc """
  Builds a map from argument value list.  For Sentry, typically the
  key in the map would be the name of the variable, but we don't have that
  available.
  """
  @spec args_from_stacktrace(Exception.stacktrace) :: String.t | nil
  def args_from_stacktrace([{_m, _f, a, _} | _]) when is_list(a) do
    Enum.with_index(a)
    |> Enum.map(fn({arg, index}) ->
      {"arg#{index}", inspect(arg)}
    end)
    |> Enum.into(%{})
  end
  def args_from_stacktrace(_), do: %{}

  defp arity_to_integer(arity) when is_list(arity), do: Enum.count(arity)
  defp arity_to_integer(arity) when is_integer(arity), do: arity

  defp is_in_app?(nil, _in_app_whitelist), do: false
  defp is_in_app?(_, []), do: false
  defp is_in_app?(module, in_app_module_whitelist) do
    split_modules = module_split(module)

    Enum.any?(in_app_module_whitelist, fn(module) ->
      whitelisted_split_modules = module_split(module)

      count = Enum.count(whitelisted_split_modules)
      Enum.take(split_modules, count) == whitelisted_split_modules
    end)
  end

  defp module_split(module) when is_binary(module) do
    String.split(module, ".")
    |> Enum.reject(&(&1 == "Elixir"))
  end
  defp module_split(module), do: module_split(String.Chars.to_string(module))
end
