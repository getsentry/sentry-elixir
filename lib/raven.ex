defmodule Raven do
  use GenEvent

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

  def capture_exception(exception) do
    case Application.get_env(:raven, :dsn) do
      dsn when is_bitstring(dsn) -> capture_exception(exception, dsn |> parse_dsn!)
      _ -> :error
    end
  end

  def capture_exception(exception, {endpoint, public_key, private_key}) do
    body = exception |> transform |> Map.from_struct |> :jiffy.encode
    headers = %{
      "User-Agent" => @sentry_client,
      "X-Sentry-Auth" => authorization_header(public_key, private_key),
    }
    case HTTPoison.post(endpoint, body, headers) do
      %HTTPoison.Response{status_code: 200, body: body} -> {:ok, body |> :jiffy.decode([:return_maps]) |> Dict.get("id")}
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
              level: :error, 
              platform: "elixir",
              server_name: nil,
              exception: nil,
              stacktrace: %{
                frames: []
              },
              extra: %{}
  end

  def transform(stacktrace) when is_bitstring(stacktrace) do
    transform(String.split(stacktrace, "\n"))
  end

  def transform(stacktrace) do
    transform(stacktrace, %Event{})
  end

  def transform(['Error in process ' ++ _=message|t], state) do
    transform(t, %{state | message: message |> to_string})
  end

  def transform(["Last message: " <> last_message|t], state) do
    transform(t, put_in(state.extra, Map.put_new(state.extra, :last_message, last_message)))
  end

  def transform(["State: " <> last_state|t], state) do
    transform(t, put_in(state.extra, Map.put_new(state.extra, :state, last_state)))
  end

  def transform(["    ** " <> message|t], state) do
    [_, type, value] = Regex.run(~r/^\((.+?)\) (.+)$/, message)
    transform(t, %{state | message: message, exception: [%{type: type, value: value}]})
  end

  def transform(["        " <> frame|t], state) do
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
      in_app: app != "stdlib",
      vars: %{},
    }])

    transform(t, state)
  end

  def transform([_|t], state) do
    transform(t, state)
  end

  def transform([], state) do
    %{state | 
      event_id: UUID.uuid4(),
      timestamp: iso8601_timestamp,
      tags: Application.get_env(:raven, :tags, %{}),
      server_name: :net_adm.localhost |> to_string}
  end

  ## Private

  defp unix_timestamp do
    {mega, sec, _micro} = :os.timestamp()
    mega * (1000000 + sec)
  end

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