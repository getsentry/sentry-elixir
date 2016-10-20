defmodule Sentry.Client do
  alias Sentry.{Event, Util}
  require Logger
  @type parsed_dsn :: {String.t, String.t, Integer.t}
  @sentry_version 5
  @max_attempts 4

  quote do
    unquote(@sentry_client "sentry-elixir/#{Mix.Project.config[:version]}")
  end

  @moduledoc """
    Provides basic HTTP client request and response handling for the Sentry API.
  """

  @doc """
  Starts an unlinked asynchronous task that will attempt to send the event to the Sentry
  API up to 4 times with exponential backoff.

  The event is dropped if it all retries fail.
  """
  @spec send_event(%Event{}) :: {:ok, String.t} | :error
  def send_event(%Event{} = event) do
    {endpoint, public_key, secret_key} = parse_dsn!(Application.fetch_env!(:sentry, :dsn))

    auth_headers = authorization_headers(public_key, secret_key)
    body = Poison.encode!(event)

    Task.start(fn ->
      try_request(:post, endpoint, auth_headers, body)
    end)
  end

  defp try_request(method, url, headers, body) do
    do_try_request(method, url, headers, body, 1)
  end

  defp do_try_request(_method, _url, _headers, _body, current_attempt) when current_attempt > @max_attempts do
    :error
  end

  defp do_try_request(method, url, headers, body, current_attempt) when current_attempt <= @max_attempts do
    case request(method, url, headers, body) do
      {:ok, id} -> {:ok, id}
      _ ->
        sleep(current_attempt)
        do_try_request(method, url, headers, body, current_attempt + 1)
    end
  end

  def request(method, url, headers, body) do
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
            :error
        end
      {:ok, status, headers, _client} ->
        error_header = :proplists.get_value("X-Sentry-Error", headers, "")
        log_api_error("#{body}\nReceived #{status} from Sentry server: #{error_header}")
        :error
      _ ->
        log_api_error(body)
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
    end)
  end

  defp sleep(attempt_number) do
    # sleep 2^n seconds
    :math.pow(attempt_number, 2)
    |> Kernel.*(1000)
    |> Kernel.round()
    |> :timer.sleep()
  end
end
