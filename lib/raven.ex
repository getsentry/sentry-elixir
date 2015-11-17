defmodule Raven do
  use GenEvent

  @moduledoc """
  Setup the application environment in your config.

      config :raven,
        dsn: "https://public:secret@app.getsentry.com/1"
        tags: %{
          env: "production"
        }

  Install the Logger backend.

      Logger.add_backend(Raven)
  """

  @type parsed_dsn :: {String.t, String.t, Integer.t}

  ## Server

  def handle_call({:configure, _options}, state) do
    {:ok, :ok, state}
  end

  def handle_event({:error, gl, {Logger, msg, _ts, _md}}, state) when node(gl) == node() do
    capture_exception(msg)
    {:ok, state}
  end

  def handle_event(_data, state) do
    {:ok, state}
  end

  ## Sentry

  @doc """
  Parses a Sentry DSN which is simply a URI.
  """
  @spec parse_dsn!(String.t) :: parsed_dsn
  def parse_dsn!(dsn) do
    # {PROTOCOL}://{PUBLIC_KEY}:{SECRET_KEY}@{HOST}/{PATH}{PROJECT_ID}
    %URI{userinfo: userinfo, host: host, path: path, scheme: protocol} = URI.parse(dsn)
    [public_key, secret_key] = userinfo |> String.split(":", parts: 2)
    {project_id, _} = path |> String.slice(1..-1) |> Integer.parse
    endpoint = "#{protocol}://#{host}/api/#{project_id}/store/"
    {endpoint, public_key, secret_key}
  end

  @sentry_version 5
  quote do
    unquote(@sentry_client "raven-elixir/#{Mix.Project.config[:version]}")
  end

  @doc """
  Generates a Sentry API authorization header.
  """
  @spec authorization_header(String.t, String.t, Integer.t) :: String.t
  def authorization_header(public_key, secret_key, timestamp \\ nil) do
    # X-Sentry-Auth: Sentry sentry_version=5,
    # sentry_client=<client version, arbitrary>,
    # sentry_timestamp=<current timestamp>,
    # sentry_key=<public api key>,
    # sentry_secret=<secret api key>
    unless timestamp do
      timestamp = unix_timestamp
    end
    "Sentry sentry_version=#{@sentry_version}, sentry_client=#{@sentry_client}, sentry_timestamp=#{timestamp}, sentry_key=#{public_key}, sentry_secret=#{secret_key}"
  end

  @doc """
  Parses and submits an exception to Sentry if DSN is setup in application env.
  """
  @spec capture_exception(String.t) :: {:ok, String.t} | :error
  def capture_exception(exception) do
    case Application.get_env(:raven, :dsn) do
      dsn when is_bitstring(dsn) -> capture_exception(exception, dsn |> parse_dsn!)
      _ -> :error
    end
  end

  @spec capture_exception(String.t, parsed_dsn) :: {:ok, String.t} | :error
  def capture_exception(exception, {endpoint, public_key, private_key}) do
    body = exception |> transform |> Poison.encode!
    headers = [
      {"User-Agent", @sentry_client},
      {"X-Sentry-Auth", authorization_header(public_key, private_key)},
    ]
    case :hackney.request(:post, endpoint, headers, body, []) do
      {:ok, 200, _headers, client} ->
        case :hackney.body(client) do
          {:ok, body} -> {:ok, body |> Poison.decode! |> Dict.get("id")}
          _ -> :error
        end
      _ -> :error
    end
  end

  ## Transformers

  defmodule Event do
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
  end

  @doc """
  Transforms a exception string to a Sentry event.
  """
  @spec transform(String.t) :: %Event{}
  def transform(stacktrace) when is_bitstring(stacktrace) do
    transform(String.split(stacktrace, "\n"))
  end

  @spec transform([String.t | char_list]) :: %Event{}
  def transform(stacktrace) do
    transform(stacktrace, %Event{})
  end

  def transform(["#PID" <> _, " running ", _endpoint, " terminated\n", _request | stacktrace], state) do
    transform(String.split(stacktrace, "\n"), state)
  end

  @spec transform([String.t | char_list], %Event{}) :: %Event{}
  def transform(['Error in process ' ++ _=message|t], state) do
    transform(t, %{state | message: message |> to_string})
  end

  @spec transform([String.t | char_list], %Event{}) :: %Event{}
  def transform(["Process ", pid, " raised an exception\n" | stacktrace], state) do
    message = "Process " <> pid <> " raised an exception"
    transform(String.split(stacktrace, "\n"), %{state | message: message |> to_string})
  end

  @spec transform([String.t | char_list], %Event{}) :: %Event{}
  def transform(["Last message: " <> last_message|t], state) do
    transform(t, put_in(state.extra, Map.put_new(state.extra, :last_message, last_message)))
  end

  @spec transform([String.t | char_list], %Event{}) :: %Event{}
  def transform(["State: " <> last_state|t], state) do
    transform(t, put_in(state.extra, Map.put_new(state.extra, :state, last_state)))
  end

  @spec transform([String.t | char_list], %Event{}) :: %Event{}
  def transform(["    Args: " <> _|t], state) do
    transform(t, state)
  end

  @spec transform([String.t | char_list], %Event{}) :: %Event{}
  def transform(["    ** " <> message|t], state) do
    transform_first_stacktrace_line([message|t], state)
  end
  @spec transform([String.t | char_list], %Event{}) :: %Event{}
  def transform(["** " <> message|t], state) do
    transform_first_stacktrace_line([message|t], state)
  end
  defp transform_first_stacktrace_line([message|t], state) do
    [_, type, value] = Regex.run(~r/^\((.+?)\) (.+)$/, message)
    transform(t, %{state | message: message, exception: [%{type: type, value: value}]})
  end

  @spec transform([String.t | char_list], %Event{}) :: %Event{}
  def transform(["        " <> frame|t], state) do
    transform_stacktrace_line([frame|t], state)
  end
  @spec transform([String.t | char_list], %Event{}) :: %Event{}
  def transform(["    " <> frame|t], state) do
    transform_stacktrace_line([frame|t], state)
  end
  defp transform_stacktrace_line([frame|t], state) do
    [app, filename, lineno, function] =
      case Regex.run(~r/^(\((.+?)\) )?(.+?):(\d+): (.+)$/, frame) do
        [_, _, filename, lineno, function] -> [:unknown, filename, lineno, function]
        [_, _, app, filename, lineno, function] -> [app, filename, lineno, function]
      end

    unless state.culprit do
      state = %{state | culprit: function}
    end

    state = put_in(state.stacktrace.frames, state.stacktrace.frames ++ [%{
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
    }])

    transform(t, state)
  end

  @spec transform([String.t | char_list], %Event{}) :: %Event{}
  def transform([_|t], state) do
    transform(t, state)
  end

  @spec transform([String.t | char_list], %Event{}) :: %Event{}
  def transform([], state) do
    %{state |
      event_id: UUID.uuid4(),
      timestamp: iso8601_timestamp,
      tags: Application.get_env(:raven, :tags, %{}),
      server_name: :net_adm.localhost |> to_string}
  end

  @spec transform(any, %Event{}) :: %Event{}
  def transform(_, state) do
    # TODO: maybe do something with this?
    state
  end

  ## Private

  @spec unix_timestamp :: Number.t
  defp unix_timestamp do
    {mega, sec, _micro} = :os.timestamp()
    mega * (1000000 + sec)
  end

  @spec unix_timestamp :: String.t
  defp iso8601_timestamp do
    [year, month, day, hour, minute, second] =
      :calendar.universal_time
      |> Tuple.to_list
      |> Enum.map(&Tuple.to_list(&1))
      |> List.flatten
      |> Enum.map(&to_string(&1))
      |> Enum.map(&String.rjust(&1, 2, ?0))
    "#{year}-#{month}-#{day}T#{hour}:#{minute}:#{second}"
  end
end
