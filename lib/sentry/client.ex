defmodule Sentry.Client do
  @behaviour Sentry.HTTPClient

  @moduledoc """
  This module is the default client for sending an event to Sentry via HTTP.

  It makes use of `Task.Supervisor` to allow sending tasks synchronously or asynchronously, and defaulting to asynchronous. See `Sentry.Client.send_event/2` for more information.

  ### Configuration

  * `:before_send_event` - allows performing operations on the event before
    it is sent.  Accepts an anonymous function or a {module, function} tuple, and
    the event will be passed as the only argument.

  Example configuration of putting Logger metadata in the extra context:

      config :sentry,
        before_send_event: fn(event) ->
          metadata = Map.new(Logger.metadata)
          %{event | extra: Map.merge(event.extra, metadata)}
        end
  """

  alias Sentry.{Event, Util}

  require Logger

  @type get_dsn :: {String.t, String.t, Integer.t}
  @sentry_version 5
  @max_attempts 4
  @hackney_pool_name :sentry_pool

  quote do
    unquote(@sentry_client "sentry-elixir/#{Mix.Project.config[:version]}")
  end

  @doc """
  Attempts to send the event to the Sentry API up to 4 times with exponential backoff.

  The event is dropped if it all retries fail.

  ### Options
  * `:result` - Allows specifying how the result should be returned. Options include `:sync`, `:none`, and `:async`.  `:sync` will make the API call synchronously, and return `{:ok, event_id}` if successful.  `:none` sends the event from an unlinked child process under `Sentry.TaskSupervisor` and will return `{:ok, ""}` regardless of the result.  `:async` will start an unlinked task and return a tuple of `{:ok, Task.t}` on success where the Task can be awaited upon to receive the result asynchronously.  When used in an OTP behaviour like GenServer, the task will send a message that needs to be matched with `GenServer.handle_info/2`.  See `Task.Supervisor.async_nolink/2` for more information.  `:async` is the default.
  """
  @spec send_event(Event.t) :: {:ok, Task.t | String.t} | :error
  def send_event(%Event{} = event, opts \\ []) do
    result = Keyword.get(opts, :result, :async)

    event = maybe_call_before_send_event(event)
    case Poison.encode(event) do
      {:ok, body} ->
        do_send_event(body, result)
      {:error, error} ->
        log_api_error("Unable to encode Sentry error - #{inspect(error)}")
        :error
    end
  end

  defp do_send_event(body, :async) do
    {endpoint, public_key, secret_key} = get_dsn!()
    auth_headers = authorization_headers(public_key, secret_key)
    {:ok, Task.Supervisor.async_nolink(Sentry.TaskSupervisor, fn ->
      try_request(:post, endpoint, auth_headers, body)
    end)}
  end

  defp do_send_event(body, :sync) do
    {endpoint, public_key, secret_key} = get_dsn!()
    auth_headers = authorization_headers(public_key, secret_key)
    try_request(:post, endpoint, auth_headers, body)
  end

  defp do_send_event(body, :none) do
    {endpoint, public_key, secret_key} = get_dsn!()
    auth_headers = authorization_headers(public_key, secret_key)
    Task.Supervisor.start_child(Sentry.TaskSupervisor, fn ->
      try_request(:post, endpoint, auth_headers, body)
    end)

    {:ok, ""}
  end

  defp try_request(method, url, headers, body, current_attempt \\ 1)
  defp try_request(_, _, _, _, current_attempt)
    when current_attempt > @max_attempts, do: :error
  defp try_request(method, url, headers, body, current_attempt) do
    case request(method, url, headers, body) do
      {:ok, id} -> {:ok, id}
      _ ->
        sleep(current_attempt)
        try_request(method, url, headers, body, current_attempt + 1)
    end
  end

  @doc """
  Makes the HTTP request to Sentry using hackney.

  Hackney options can be set via the `hackney_opts` configuration option.
  """
  def request(method, url, headers, body) do
    hackney_opts = Application.get_env(:sentry, :hackney_opts, [])
                   |> Keyword.put_new(:pool, @hackney_pool_name)
    with {:ok, 200, _, client} <- :hackney.request(method, url, headers, body, hackney_opts),
         {:ok, body} <- :hackney.body(client),
         {:ok, json} <- Poison.decode(body) do
      {:ok, Map.get(json, "id")}
    else
      {:ok, status, headers, client} ->
        :hackney.skip_body(client)
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
    data = [
      sentry_version: @sentry_version,
      sentry_client: @sentry_client,
      sentry_timestamp: timestamp,
      sentry_key: public_key,
      sentry_secret: secret_key
    ]
    query = data
            |> Enum.map(fn {name, value} -> "#{name}=#{value}" end)
            |> Enum.join(", ")
    "Sentry " <> query
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

  def maybe_call_before_send_event(event) do
    case Application.get_env(:sentry, :before_send_event) do
      function when is_function(function, 1) ->
        function.(event)
      {module, function} ->
        apply(module, function, [event])
      nil ->
        event
      _ ->
        raise ArgumentError, message: ":before_send_event must be an anonymous function or a {Module, Function} tuple"
    end
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
    :math.pow(2, attempt_number)
    |> Kernel.*(1000)
    |> Kernel.round()
    |> :timer.sleep()
  end
end
