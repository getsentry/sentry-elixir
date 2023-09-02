defmodule Sentry.Client do
  @moduledoc """
  This module interfaces directly with Sentry via HTTP.

  See `Sentry.HTTPClient` for more information. This module provides an interface
  to talk to Sentry through the configured HTTP client.

  Most of the time, **you won't have to use this module** directly. Instead, you
  will mostly use the functions in the `Sentry` module.

  ## Sending Events

  This module makes use of `Task.Supervisor` to allow sending events
  synchronously or asynchronously, defaulting to asynchronous.
  See `send_event/2` for more information.
  """

  alias Sentry.{Config, Event, Interfaces}

  require Logger

  @type send_event_result ::
          {:ok, Task.t() | String.t()} | {:error, any()} | :unsampled | :excluded
  @type dsn :: {String.t(), String.t(), String.t()}
  @type result :: :sync | :none | :async
  @sentry_version 5
  @sentry_client "sentry-elixir/#{Mix.Project.config()[:version]}"

  # Max message length per https://github.com/getsentry/sentry/blob/0fcec33ac94ad81a205f86f208072b0f57b39ff4/src/sentry/conf/server.py#L1021
  @max_message_length 8_192

  @doc """
  Attempts to send the event to the Sentry API up to 4 times with exponential backoff.

  The event is dropped if it all retries fail.
  Errors will be logged unless the source is the `Sentry.LoggerBackend`, which can
  deadlock by logging within a logger.

  ### Options

  * `:result` - Allows specifying how the result should be returned. The possible values are:

    * `:sync` - Sentry will make an API call synchronously (including retries) and will
      return `{:ok, event_id}` if successful.

    * `:none` - Sentry will send the event in the background, in a *fire-and-forget*
      fashion. The function will return `{:ok, ""}` regardless of whether the API
      call ends up being successful or not.

    * `:async` - **not supported anymore**, see the information below.

  * `:sample_rate` - The sampling factor to apply to events.  A value of 0.0 will deny sending
    any events, and a value of 1.0 will send 100% of events.

  * Other options, such as `:stacktrace` or `:extra` will be passed to `Sentry.Event.create_event/1`
    downstream. See `Sentry.Event.create_event/1` for available options.

  > #### Async Send {: .error}
  >
  > Before v9.0.0 of this library, the `:result` option also supported the `:async` value.
  > This would spawn a `Task` to make the API call, and would return a `{:ok, Task.t()}` tuple.
  > You could use `Task` operations to wait for the result asynchronously. Since v9.0.0, this
  > option is not present anymore. Instead, you can spawn a task yourself that then calls this
  > function with `result: :sync`. The effect is exactly the same.

  """
  @spec send_event(Event.t()) :: send_event_result
  def send_event(%Event{} = event, opts \\ []) do
    result = Keyword.get(opts, :result, Config.send_result())
    sample_rate = Keyword.get(opts, :sample_rate, Config.sample_rate())

    case {maybe_call_before_send_event(event), sample_event?(sample_rate)} do
      {false, _} -> :excluded
      {%Event{}, false} -> :unsampled
      {%Event{} = event, true} -> encode_and_send(event, result)
    end
  end

  defp encode_and_send(_event, :async) do
    raise ArgumentError, """
    the :async result type is not supported anymore. Instead, you can spawn a task yourself that \
    then calls Sentry.send_event/2 with result: :sync. The effect is exactly the same.
    """
  end

  defp encode_and_send(%Event{} = event, result_type) do
    result =
      event
      |> Sentry.Envelope.new()
      |> Sentry.Envelope.to_binary()
      |> case do
        {:ok, body} ->
          do_send_event(event, body, result_type)

        {:error, error} ->
          {:error, {:invalid_json, error}}
      end

    if match?({:ok, _}, result) do
      Sentry.put_last_event_id_and_source(event.event_id, event.__source__)
    end

    maybe_log_result(result, event)

    result
  end

  @spec do_send_event(Event.t(), binary(), :sync) :: {:ok, String.t()} | {:error, any()}
  defp do_send_event(event, body, :sync) do
    case get_headers_and_endpoint() do
      {endpoint, auth_headers} when is_binary(endpoint) ->
        try_request(endpoint, auth_headers, {event, body}, Config.send_max_attempts())
        |> maybe_call_after_send_event(event)

      {:error, :invalid_dsn} ->
        {:error, :invalid_dsn}
    end
  end

  @spec do_send_event(Event.t(), binary(), :none) :: {:ok, String.t()} | {:error, any()}
  defp do_send_event(event, body, :none) do
    case get_headers_and_endpoint() do
      {endpoint, auth_headers} when is_binary(endpoint) ->
        Task.Supervisor.start_child(Sentry.TaskSupervisor, fn ->
          try_request(endpoint, auth_headers, {event, body}, Config.send_max_attempts())
          |> maybe_call_after_send_event(event)
          |> maybe_log_result(event)
        end)

        {:ok, ""}

      {:error, :invalid_dsn} ->
        {:error, :invalid_dsn}
    end
  end

  @spec try_request(
          String.t(),
          list({String.t(), String.t()}),
          {Event.t(), String.t()},
          pos_integer(),
          {pos_integer(), any()}
        ) :: {:ok, String.t()} | {:error, {:request_failure, any()}}
  defp try_request(url, headers, event_body_tuple, max_attempts, current \\ {1, nil})

  defp try_request(_url, _headers, {_event, _body}, max_attempts, {current_attempt, last_error})
       when current_attempt > max_attempts,
       do: {:error, {:request_failure, last_error}}

  defp try_request(url, headers, {event, body}, max_attempts, {current_attempt, _last_error}) do
    case request(url, headers, body) do
      {:ok, id} ->
        {:ok, id}

      {:error, error} ->
        if current_attempt < max_attempts, do: sleep(current_attempt)
        try_request(url, headers, {event, body}, max_attempts, {current_attempt + 1, error})
    end
  end

  @doc """
  Makes an HTTP request to Sentry using the configured HTTP client.

  If the request returns a `200` response status code, then this function returns
  the `"id"` found in the JSON response body (or `nil` if none is found). If the
  request fails returns any other status code, invalid JSON, or fails, then
  this function returns `{:error, reason}`.
  """
  @spec request(String.t(), [{String.t(), String.t()}], String.t()) ::
          {:ok, String.t() | nil} | {:error, reason :: term()}
  def request(url, headers, body) when is_binary(url) and is_list(headers) do
    json_library = Config.json_library()

    with {:ok, 200, _, body} <- Config.client().post(url, headers, body),
         {:ok, json} <- json_library.decode(body) do
      {:ok, Map.get(json, "id")}
    else
      {:ok, status, headers, _body} ->
        error_header = :proplists.get_value("X-Sentry-Error", headers, "")
        error = "Received #{status} from Sentry server: #{error_header}"
        {:error, error}

      {:error, reason} ->
        {:error, reason}
    end
  catch
    kind, data -> {:error, {kind, data, __STACKTRACE__}}
  end

  @doc """
  Generates a Sentry API authorization header.
  """
  @spec authorization_header(String.t(), String.t()) :: String.t()
  def authorization_header(public_key, secret_key) do
    timestamp = System.system_time(:second)

    data = [
      sentry_version: @sentry_version,
      sentry_client: @sentry_client,
      sentry_timestamp: timestamp,
      sentry_key: public_key,
      sentry_secret: secret_key
    ]

    query =
      data
      |> Enum.filter(fn {_, value} -> value != nil end)
      |> Enum.map(fn {name, value} -> "#{name}=#{value}" end)
      |> Enum.join(", ")

    "Sentry " <> query
  end

  @doc """
  Get a Sentry DSN which is simply a URI.

  {PROTOCOL}://{PUBLIC_KEY}[:{SECRET_KEY}]@{HOST}/{PATH}{PROJECT_ID}
  """
  @spec get_dsn :: dsn | {:error, :invalid_dsn}
  def get_dsn do
    dsn = Config.dsn()

    with dsn when is_binary(dsn) <- dsn,
         %URI{userinfo: userinfo, host: host, port: port, path: path, scheme: protocol}
         when is_binary(path) and is_binary(userinfo) <- URI.parse(dsn),
         [public_key, secret_key] <- keys_from_userinfo(userinfo),
         uri_path <- String.split(path, "/"),
         {binary_project_id, uri_path} <- List.pop_at(uri_path, -1),
         base_path <- Enum.join(uri_path, "/"),
         {project_id, ""} <- Integer.parse(binary_project_id),
         endpoint <- "#{protocol}://#{host}:#{port}#{base_path}/api/#{project_id}/envelope/" do
      {endpoint, public_key, secret_key}
    else
      _ ->
        {:error, :invalid_dsn}
    end
  end

  @spec maybe_call_after_send_event(send_event_result, Event.t()) :: send_event_result
  def maybe_call_after_send_event(result, event) do
    case Config.after_send_event() do
      function when is_function(function, 2) ->
        function.(event, result)

      {module, function} ->
        apply(module, function, [event, result])

      nil ->
        nil

      _ ->
        raise ArgumentError,
          message: ":after_send_event must be an anonymous function or a {Module, Function} tuple"
    end

    result
  end

  @spec maybe_call_before_send_event(Event.t()) :: Event.t() | false
  def maybe_call_before_send_event(event) do
    case Config.before_send_event() do
      function when is_function(function, 1) ->
        function.(event) || false

      {module, function} ->
        apply(module, function, [event]) || false

      nil ->
        event

      _ ->
        raise ArgumentError,
          message:
            ":before_send_event must be an anonymous function or a {Module, Function} tuple"
    end
  end

  @doc """
  Transform a Sentry event into a JSON-encodable map.

  Some event attributes map directly to JSON, while others are structs that need to
  be converted to maps. This function does that conversion.

  ## Examples

      iex> event = Sentry.Event.create_event(message: "Something went wrong", extra: %{foo: "bar"})
      iex> jsonable_map = render_event(event)
      iex> jsonable_map[:message]
      "Something went wrong"
      iex> jsonable_map[:level]
      :error
      iex> jsonable_map[:extra]
      %{foo: "bar"}

  """
  @spec render_event(Event.t()) :: map()
  def render_event(%Event{} = event) do
    event
    |> Map.from_struct()
    |> update_if_present(:message, &String.slice(&1, 0, @max_message_length))
    |> update_if_present(:breadcrumbs, fn bcs -> Enum.map(bcs, &Map.from_struct/1) end)
    |> update_if_present(:sdk, &Map.from_struct/1)
    |> update_if_present(:exception, &[render_exception(&1)])
    |> Map.drop([:__source__, :__original_exception__])
  end

  defp render_exception(%Interfaces.Exception{} = exception) do
    exception
    |> Map.from_struct()
    |> update_if_present(:stacktrace, fn %Interfaces.Stacktrace{frames: frames} ->
      %{frames: Enum.map(frames, &Map.from_struct/1)}
    end)
  end

  defp update_if_present(map, key, fun) do
    case Map.pop(map, key) do
      {nil, _} -> map
      {value, map} -> Map.put(map, key, fun.(value))
    end
  end

  @spec maybe_log_result(send_event_result, Event.t()) :: send_event_result
  def maybe_log_result(result, event) do
    if should_log?(event) do
      message =
        case result do
          {:error, :invalid_dsn} ->
            "Cannot send Sentry event because of invalid DSN"

          {:error, {:invalid_json, error}} ->
            "Unable to encode JSON Sentry error - #{inspect(error)}"

          {:error, {:request_failure, last_error}} ->
            case last_error do
              {kind, data, stacktrace}
              when kind in [:exit, :throw, :error] and is_list(stacktrace) ->
                Exception.format(kind, data, stacktrace)

              _other ->
                "Error in HTTP Request to Sentry - #{inspect(last_error)}"
            end

          {:error, error} ->
            inspect(error)

          _ ->
            nil
        end

      if message do
        Logger.log(
          Config.log_level(),
          fn ->
            ["Failed to send Sentry event. ", message]
          end,
          domain: [:sentry]
        )
      end
    end

    result
  end

  @spec authorization_headers(String.t(), String.t()) :: list({String.t(), String.t()})
  defp authorization_headers(public_key, secret_key) do
    [
      {"User-Agent", @sentry_client},
      {"X-Sentry-Auth", authorization_header(public_key, secret_key)}
    ]
  end

  defp keys_from_userinfo(userinfo) do
    case String.split(userinfo, ":", parts: 2) do
      [public, secret] -> [public, secret]
      [public] -> [public, nil]
      _ -> :error
    end
  end

  @spec get_headers_and_endpoint ::
          {String.t(), list({String.t(), String.t()})} | {:error, :invalid_dsn}
  defp get_headers_and_endpoint do
    case get_dsn() do
      {endpoint, public_key, secret_key} ->
        {endpoint, authorization_headers(public_key, secret_key)}

      {:error, :invalid_dsn} ->
        {:error, :invalid_dsn}
    end
  end

  @spec sleep(pos_integer()) :: :ok
  defp sleep(1), do: :timer.sleep(2000)
  defp sleep(2), do: :timer.sleep(4000)
  defp sleep(3), do: :timer.sleep(8000)
  defp sleep(_), do: :timer.sleep(8000)

  @spec sample_event?(number()) :: boolean()
  defp sample_event?(1), do: true
  defp sample_event?(1.0), do: true
  defp sample_event?(0), do: false
  defp sample_event?(0.0), do: false

  defp sample_event?(sample_rate) do
    :rand.uniform() < sample_rate
  end

  defp should_log?(%Event{__source__: event_source}) do
    event_source != :logger
  end
end
