defmodule Sentry.Client do
  alias Sentry.{Event, Util}
  require Logger
  @type parsed_dsn :: {String.t, String.t, Integer.t}
  @sentry_version 5

  quote do
    unquote(@sentry_client "sentry-elixir/#{Mix.Project.config[:version]}")
  end

  @moduledoc """
    Provides basic HTTP client request and response handling for the Sentry API.
  """

  @spec send_event(%Event{}) :: {:ok, String.t} | :error
  def send_event(%Event{} = event) do
    {endpoint, public_key, secret_key} = parse_dsn!(Application.fetch_env!(:sentry, :dsn))

    auth_headers = authorization_headers(public_key, secret_key)

    request(:post, endpoint, auth_headers, event)
  end

  @spec send_event(%Event{}) :: {:ok, String.t} | :error
  def request(method, url, headers, body) do
    case :fuse.ask(Sentry.Fuse.api_fuse_name(), :sync) do
      :ok ->
        do_request(method, url, headers, body)
      :blown ->
        :error
    end
  end

  defp do_request(method, url, headers, body) do
    body = Poison.encode!(body)
    case :hackney.request(method, url, headers, body, []) do
      {:ok, 200, _headers, client} ->
        case :hackney.body(client) do
          {:ok, body} ->
            id = body
              |> Poison.decode!()
              |> Map.get("id")
            {:ok, id}
          _ ->
            log_api_error(body)
        end
      _ ->
        log_api_error(body)
        Sentry.Fuse.api_fuse_name()
        |> :fuse.melt()

        :error
    end
  end

  @doc """
  Generates a Sentry API authorization header.
  """
  @spec authorization_header(String.t, String.t) :: String.t
  def authorization_header(public_key, secret_key) do
    timestamp = Util.unix_timestamp()
    "Sentry sentry_version=#{@sentry_version}, sentry_client=#{@sentry_client}, sentry_timestamp=#{timestamp}, sentry_key=#{public_key}, sentry_secret=#{secret_key}"
  end

  def authorization_headers(public_key, secret_key) do
    [
      {"User-Agent", @sentry_client},
      {"X-Sentry-Auth", authorization_header(public_key, secret_key)}
    ]
  end

  @doc """
  Parses a Sentry DSN which is simply a URI.
  """
  @spec parse_dsn!(String.t) :: parsed_dsn
  def parse_dsn!(dsn) do
    # {PROTOCOL}://{PUBLIC_KEY}:{SECRET_KEY}@{HOST}/{PATH}{PROJECT_ID}
    %URI{userinfo: userinfo, host: host, port: port, path: path, scheme: protocol} = URI.parse(dsn)
    [public_key, secret_key] = String.split(userinfo, ":", parts: 2)
    [_, binary_project_id] = String.split(path, "/")
    project_id = String.to_integer(binary_project_id)
    endpoint = "#{protocol}://#{host}:#{port}/api/#{project_id}/store/"

    {endpoint, public_key, secret_key}
  end

  defp log_api_error(body) do
    Logger.error(fn ->
      ["Failed to send sentry event.", ?\n, body]
    end, [skip_sentry: true])
  end
end
