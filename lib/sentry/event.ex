defmodule Sentry.Event do
  @moduledoc """
    Provides an Event Struct as well as transformation of Logger
    entries into Sentry Events.
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
            breadcrumbs: []

  @type t :: %__MODULE__{}

  alias Sentry.{Event, Util}
  @source_code_context_enabled Application.fetch_env!(:sentry, :enable_source_code_context)
  @source_files if(@source_code_context_enabled, do: Sentry.Sources.load_files(), else: nil)

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

    extra = extra_context
            |> Map.merge(Keyword.get(opts, :extra, %{}))
    user = user_context
           |> Map.merge(Keyword.get(opts, :user, %{}))
    tags = Application.get_env(:sentry, :tags, %{})
           |> Map.merge(tags_context)
           |> Map.merge(Keyword.get(opts, :tags, %{}))
    request = request_context
              |> Map.merge(Keyword.get(opts, :request, %{}))
    breadcrumbs = Keyword.get(opts, :breadcrumbs, []) ++ breadcrumbs_context

    level = Keyword.get(opts, :level, "error")

    release = Application.get_env(:sentry, :release)

    server_name = Application.get_env(:sentry, :server_name)

    env = Application.get_env(:sentry, :environment_name)

    %Event{
      culprit: culprit_from_stacktrace(stacktrace),
      message: message,
      level: level,
      platform: "elixir",
      environment: env,
      server_name: server_name,
      exception: exception,
      stacktrace: %{
        frames: stacktrace_to_frames(stacktrace)
      },
      release: release,
      extra: extra,
      tags: tags,
      user: user,
      breadcrumbs: breadcrumbs,
      request: request
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
  def add_metadata(state) do
    %{state |
     event_id: UUID.uuid4(:hex),
     timestamp: Util.iso8601_timestamp(),
     server_name: to_string(:net_adm.localhost)}
  end

  @spec stacktrace_to_frames(Exception.stacktrace) :: [map]
  def stacktrace_to_frames(stacktrace) do
    stacktrace
    |> Enum.map(fn(line) ->
        {mod, function, arity, location} = line
        arity = arity_to_integer(arity)
        file = Keyword.get(location, :file)
        file = if(file, do: String.Chars.to_string(file), else: file)
        line_number = Keyword.get(location, :line)

        %{
          filename: file && to_string(file),
          function: Exception.format_mfa(mod, function, arity),
          module: mod,
          lineno: line_number,
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
  def culprit_from_stacktrace([{m, f, a, _} | _]), do: Exception.format_mfa(m, f, a)

  defp arity_to_integer(arity) when is_list(arity), do: Enum.count(arity)
  defp arity_to_integer(arity) when is_integer(arity), do: arity
end
