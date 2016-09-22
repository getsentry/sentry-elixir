defmodule Sentry.Event do
  alias Sentry.{Event, Util}

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
  @spec transform_exception(Exception.t, Keyword.t) :: %Event{}
  def transform_exception(exception, opts) do
    %{user: user_context,
     tags: tags_context,
     extra: extra_context,
     breadcrumbs: breadcrumbs_context} = Sentry.Context.get_all()

    stacktrace = Keyword.get(opts, :stacktrace, [])

    extra = extra_context
            |> Map.merge(Keyword.get(opts, :extra, %{}))
    user = user_context
            |> Map.merge(Keyword.get(opts, :user, %{}))
    tags = Application.get_env(:sentry, :tags, %{})
            |> Dict.merge(tags_context)
            |> Dict.merge(Keyword.get(opts, :tags, %{}))
    request = Keyword.get(opts, :request, %{})
    breadcrumbs = Keyword.get(opts, :breadcrumbs, [])
                  |> Kernel.++(breadcrumbs_context)

    level = Keyword.get(opts, :level, "error")

    exception = Exception.normalize(:error, exception)

    message = :error
      |> Exception.format_banner(exception)
      |> String.trim("*")
      |> String.trim

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
      exception: [%{type: exception.__struct__, value: Exception.message(exception)}],
      stacktrace: %{
        frames: stacktrace_to_frames(stacktrace)
      },
      release: release,
      extra: extra,
      tags: tags,
      user: user,
      breadcrumbs: breadcrumbs,
    }
    |> add_metadata()
    |> Map.put(:request, request)
  end

  @spec add_metadata(%Event{}) :: %Event{}
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
        file = Keyword.get(location, :file)
        line_number = Keyword.get(location, :line)
        %{
          filename: file && to_string(file),
          function: Exception.format_mfa(mod, function, arity),
          module: mod,
          lineno: line_number,
        }
      end)
    |> Enum.reverse()
  end

  @spec culprit_from_stacktrace(Exception.stacktrace) :: String.t | nil
  def culprit_from_stacktrace([]), do: nil
  def culprit_from_stacktrace([{m, f, a, _} | _]), do: Exception.format_mfa(m, f, a)
end
