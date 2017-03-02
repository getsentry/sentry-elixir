defmodule Sentry.Client do
  alias Sentry.{Event, Util}

  require Logger

  @type get_dsn :: {String.t, String.t, Integer.t}
  @sentry_version 5
  @max_attempts 4
  @hackney_pool_name :sentry_pool

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
  @spec send_event(Event.t) :: Task.t
  def send_event(%Event{} = event) do
    {endpoint, public_key, secret_key} = get_dsn!()

    auth_headers = authorization_headers(public_key, secret_key)
    case Poison.encode(event) do
      {:ok, body} ->
        Task.Supervisor.async_nolink(Sentry.TaskSupervisor, fn ->
          try_request(:post, endpoint, auth_headers, body)
        end)
      {:error, error} ->
        log_api_error("Unable to encode Sentry error - #{inspect(error)}")
        :error
    end
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

  @doc """
  Makes the HTTP request to Sentry using hackney.

  Hackney options can be set via the `hackney_opts` configuration option.
  """
  def request(method, url, headers, body) do
    hackney_opts = Application.get_env(:sentry, :hackney_opts, [])
                   |> Keyword.put_new(:pool, @hackney_pool_name)
    case :hackney.request(method, url, headers, body, hackney_opts) do
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

  defp authorization_headers(public_key, secret_key) do
    [
      {"User-Agent", @sentry_client},
      {"X-Sentry-Auth", authorization_header(public_key, secret_key)}
    ]
  end

  @doc """
  Get a Sentry DSN which is simply a URI.
  """
  @spec get_dsn! :: get_dsn
  def get_dsn! do
    # {PROTOCOL}://{PUBLIC_KEY}:{SECRET_KEY}@{HOST}/{PATH}{PROJECT_ID}
    %URI{userinfo: userinfo, host: host, port: port, path: path, scheme: protocol} = URI.parse(fetch_dsn())
    [public_key, secret_key] = String.split(userinfo, ":", parts: 2)
    [_, binary_project_id] = String.split(path, "/")
    project_id = String.to_integer(binary_project_id)
    endpoint = "#{protocol}://#{host}:#{port}/api/#{project_id}/store/"

    {endpoint, public_key, secret_key}
  end

  def hackney_pool_name do
    @hackney_pool_name
  end

  defp fetch_dsn do
    case Application.fetch_env!(:sentry, :dsn) do
      {:system, env_var} -> System.get_env(env_var)
      value -> value
    end
  end

  defp log_api_error(body) do
    Logger.warn(fn ->
      ["Failed to send Sentry event.", ?\n, body]
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
