defmodule Sentry.Event do
  alias Sentry.{Event, Util}

  defstruct event_id: nil,
  culprit: nil,
  timestamp: nil,
  message: nil,
  tags: %{},
  level: "error",
  platform: "elixir",
  server_name: nil,
  exception: nil,
  stacktrace: %{
    frames: []
  },
  extra: %{}

  @doc """
  Transforms an exception string to a Sentry event.
  """
  @spec transform_exception(String.t, Keyword.t) :: %Event{}
  def transform_exception(exception, opts) do
    stacktrace = Keyword.get(opts, :stacktrace, [])
    extra = Keyword.get(opts, :extra, %{})
    %Event{
    }
    |> add_metadata()
  end

  @doc """
  Transforms an exception string to a Sentry event.
  """
  @spec transform_logger_stacktrace(String.t) :: %Event{}
  def transform_logger_stacktrace(stacktrace) do
    :erlang.iolist_to_binary(stacktrace)
    |> String.split("\n")
    |> transform_logger_stacktrace(%Event{})
  end

  @spec transform_logger_stacktrace([String.t], %Event{}) :: %Event{}
  def transform_logger_stacktrace(["Error in process " <> _ = message|t], state) do
    transform_logger_stacktrace(t, %{state | message: message})
  end

  @spec transform_logger_stacktrace([String.t], %Event{}) :: %Event{}
  def transform_logger_stacktrace(["Last message: " <> last_message|t], state) do
    transform_logger_stacktrace(t, put_in(state.extra, Map.put_new(state.extra, :last_message, last_message)))
  end

  @spec transform_logger_stacktrace([String.t], %Event{}) :: %Event{}
  def transform_logger_stacktrace(["State: " <> last_state|t], state) do
    transform_logger_stacktrace(t, put_in(state.extra, Map.put_new(state.extra, :state, last_state)))
  end

  @spec transform_logger_stacktrace([String.t], %Event{}) :: %Event{}
  def transform_logger_stacktrace(["Function: " <> function|t], state) do
    transform_logger_stacktrace(t, put_in(state.extra, Map.put_new(state.extra, :function, function)))
  end

  @spec transform_logger_stacktrace([String.t], %Event{}) :: %Event{}
  def transform_logger_stacktrace(["    Args: " <> args|t], state) do
    transform_logger_stacktrace(t, put_in(state.extra, Map.put_new(state.extra, :args, args)))
  end

  @spec transform_logger_stacktrace([String.t], %Event{}) :: %Event{}
  def transform_logger_stacktrace(["    ** " <> message|t], state) do
    transform_first_stacktrace_line([message|t], state)
  end

  @spec transform_logger_stacktrace([String.t], %Event{}) :: %Event{}
  def transform_logger_stacktrace(["** " <> message|t], state) do
    transform_first_stacktrace_line([message|t], state)
  end

  @spec transform_logger_stacktrace([String.t], %Event{}) :: %Event{}
  def transform_logger_stacktrace(["        " <> frame|t], state) do
    transform_stacktrace_line([frame|t], state)
  end

  @spec transform_logger_stacktrace([String.t], %Event{}) :: %Event{}
  def transform_logger_stacktrace(["    " <> frame|t], state) do
    transform_stacktrace_line([frame|t], state)
  end

  @spec transform_logger_stacktrace([String.t], %Event{}) :: %Event{}
  def transform_logger_stacktrace([_|t], state) do
    transform_logger_stacktrace(t, state)
  end

  @spec transform_logger_stacktrace([String.t], %Event{}) :: %Event{}
  def transform_logger_stacktrace([], state) do
    add_metadata(state)
  end

  @spec transform_logger_stacktrace(any, %Event{}) :: %Event{}
  def transform_logger_stacktrace(_, state) do
    # TODO: maybe do something with this?
    state
  end

  @spec add_metadata(%Event{}) :: %Event{}
  def add_metadata(state) do
    %{state |
     event_id: UUID.uuid4(:hex),
     timestamp: Util.iso8601_timestamp(),
     tags: Application.get_env(:sentry, :tags, %{}),
     server_name: to_string(:net_adm.localhost)}
  end

  ## Private

  defp transform_first_stacktrace_line([message|t], state) do
    [_, type, value] = Regex.run(~r/^\((.+?)\) (.+)$/, message)
    transform_logger_stacktrace(t, %{state | message: message, exception: [%{type: type, value: value}]})
  end

  defp transform_stacktrace_line([frame|t], state) do
    match =
      case Regex.run(~r/^(\((.+?)\) )?(.+?):(\d+): (.+)$/, frame) do
        [_, _, filename, lineno, function] -> [:unknown, filename, lineno, function]
        [_, _, app, filename, lineno, function] -> [app, filename, lineno, function]
        _ -> :no_match
      end

    case match do
      [app, filename, lineno, function] ->
        state = if state.culprit, do: state, else: %{state | culprit: function}

        state = put_in(state.stacktrace.frames, [%{
           filename: filename,
           function: function,
           module: nil,
           lineno: String.to_integer(lineno),
           colno: nil,
           abs_path: nil,
           context_line: nil,
           pre_context: nil,
           post_context: nil,
           in_app: not app in ["stdlib", "elixir"],
           vars: %{},
         } | state.stacktrace.frames])

     transform_logger_stacktrace(t, state)
     :no_match -> transform_logger_stacktrace(t, state)
    end
  end
end
