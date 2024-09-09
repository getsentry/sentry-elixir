defmodule Sentry.Client do
  @moduledoc false

  # A Client is the part of the SDK that is responsible for event creation, running callbacks,
  # and sampling.
  # See https://develop.sentry.dev/sdk/unified-api/#client.

  alias Sentry.{
    CheckIn,
    ClientError,
    Config,
    Dedupe,
    Envelope,
    Event,
    Interfaces,
    LoggerUtils,
    Transport
  }

  require Logger

  # Max message length per https://github.com/getsentry/sentry/blob/0fcec33ac94ad81a205f86f208072b0f57b39ff4/src/sentry/conf/server.py#L1021
  @max_message_length 8_192

  # The docs for the options here are generated in the Sentry module, so you can refer to types
  # and functions and so on like if you were writing these docs in the Sentry module itself.
  send_event_opts_schema = [
    result: [
      type: {:in, [:sync, :none]},
      doc: """
      Allows specifying how the result should be returned. The possible values are:

      * `:sync` - Sentry will make an API call synchronously (including retries) and will
        return `{:ok, event_id}` if successful.

      * `:none` - Sentry will send the event in the background, in a *fire-and-forget*
        fashion. The function will return `{:ok, ""}` regardless of whether the API
        call ends up being successful or not.
      """
    ],
    sample_rate: [
      type: :float,
      doc: """
      Same as the global `:sample_rate` configuration, but applied only to
      this call. See the module documentation. *Available since v10.0.0*.
      """
    ],
    before_send: [
      type: {:or, [{:fun, 1}, {:tuple, [:atom, :atom]}]},
      type_doc: "`t:before_send_event_callback/0`",
      doc: """
      Same as the global `:before_send` configuration, but
      applied only to this call. See the module documentation. *Available since v10.0.0*.
      """
    ],
    after_send_event: [
      type: {:or, [{:fun, 2}, {:tuple, [:atom, :atom]}]},
      type_doc: "`t:after_send_event_callback/1`",
      doc: """
      Same as the global `:after_send_event` configuration, but
      applied only to this call. See the module documentation. *Available since v10.0.0*.
      """
    ],
    client: [
      type: :atom,
      type_doc: "`t:module/0`",
      doc: """
      Same as the global `:client` configuration, but
      applied only to this call. See the module documentation. *Available since v10.0.0*.
      """
    ],

    # Private options, only used in testing.
    request_retries: [
      type: {:list, :integer},
      doc: false
    ]
  ]

  @send_event_opts_schema NimbleOptions.new!(send_event_opts_schema)
  @send_event_opts_keys Keyword.keys(send_event_opts_schema)

  @spec send_events_opts_schema() :: NimbleOptions.t()
  def send_events_opts_schema, do: @send_event_opts_schema

  @spec split_send_event_opts(keyword()) :: {keyword(), keyword()}
  def split_send_event_opts(options) when is_list(options) do
    Keyword.split(options, @send_event_opts_keys)
  end

  @spec send_check_in(CheckIn.t(), keyword()) ::
          {:ok, check_in_id :: String.t()} | {:error, term()}
  def send_check_in(%CheckIn{} = check_in, opts) when is_list(opts) do
    client = Keyword.get_lazy(opts, :client, &Config.client/0)

    # This is a "private" option, only really used in testing.
    request_retries =
      Keyword.get_lazy(opts, :request_retries, fn ->
        Application.get_env(:sentry, :request_retries, Transport.default_retries())
      end)

    send_result =
      check_in
      |> Envelope.from_check_in()
      |> Transport.post_envelope(client, request_retries)

    _ = maybe_log_send_result(send_result, check_in)
    send_result
  end

  # This is what executes the "Event Pipeline".
  # See: https://develop.sentry.dev/sdk/unified-api/#event-pipeline
  @spec send_event(Event.t(), keyword()) ::
          {:ok, event_id :: String.t()}
          | {:error, ClientError.t()}
          | :unsampled
          | :excluded
  def send_event(%Event{} = event, opts) when is_list(opts) do
    opts = validate_options!(opts)

    result_type = Keyword.get_lazy(opts, :result, &Config.send_result/0)
    sample_rate = Keyword.get_lazy(opts, :sample_rate, &Config.sample_rate/0)
    before_send = Keyword.get_lazy(opts, :before_send, &Config.before_send/0)
    after_send_event = Keyword.get_lazy(opts, :after_send_event, &Config.after_send_event/0)
    client = Keyword.get_lazy(opts, :client, &Config.client/0)

    # This is a "private" option, only really used in testing.
    request_retries =
      Keyword.get_lazy(opts, :request_retries, fn ->
        Application.get_env(:sentry, :request_retries, Transport.default_retries())
      end)

    result =
      with {:ok, %Event{} = event} <- maybe_call_before_send(event, before_send),
           :ok <- sample_event(sample_rate),
           :ok <- maybe_dedupe(event) do
        send_result = encode_and_send(event, result_type, client, request_retries)
        _ignored = maybe_call_after_send(event, send_result, after_send_event)
        send_result
      end

    case result do
      {:ok, _id} ->
        Sentry.put_last_event_id_and_source(event.event_id, event.source)
        result

      :unsampled ->
        # See https://github.com/getsentry/develop/pull/551/files
        Sentry.put_last_event_id_and_source(event.event_id, event.source)
        :unsampled

      :excluded ->
        :excluded

      {:error, {status, headers, body}} ->
        {:error, ClientError.server_error(status, headers, body)}

      {:error, reason} ->
        {:error, ClientError.new(reason)}
    end
  end

  @spec validate_options!(keyword()) :: keyword()
  def validate_options!(opts) when is_list(opts) do
    NimbleOptions.validate!(opts, @send_event_opts_schema)
  end

  defp sample_event(sample_rate) do
    cond do
      sample_rate == 1 -> :ok
      sample_rate == 0 -> :unsampled
      :rand.uniform() < sample_rate -> :ok
      true -> :unsampled
    end
  end

  defp maybe_dedupe(%Event{} = event) do
    if Config.dedup_events?() do
      case Dedupe.insert(event) do
        :new ->
          :ok

        :existing ->
          LoggerUtils.log(
            "Event dropped due to being a duplicate of a previously-captured event."
          )

          :excluded
      end
    else
      :ok
    end
  end

  defp maybe_call_before_send(event, nil) do
    {:ok, event}
  end

  defp maybe_call_before_send(event, callback) do
    if result = call_before_send(event, callback) do
      {:ok, result}
    else
      :excluded
    end
  end

  defp call_before_send(event, function) when is_function(function, 1) do
    function.(event) || false
  end

  defp call_before_send(event, {mod, fun}) do
    apply(mod, fun, [event]) || false
  end

  defp call_before_send(_event, other) do
    raise ArgumentError, """
    :before_send must be an anonymous function or a {module, function} tuple, got: \
    #{inspect(other)}\
    """
  end

  defp maybe_call_after_send(%Event{} = event, result, callback) do
    message = ":after_send_event must be an anonymous function or a {module, function} tuple"

    case callback do
      function when is_function(function, 2) -> function.(event, result)
      {module, function} -> apply(module, function, [event, result])
      nil -> nil
      _ -> raise ArgumentError, message
    end
  end

  defp encode_and_send(_event, _result_type = :async, _client, _request_retries) do
    raise ArgumentError, """
    the :async result type is not supported anymore. Instead, you can spawn a task yourself that \
    then calls Sentry.send_event/2 with result: :sync. The effect is exactly the same.
    """
  end

  defp encode_and_send(%Event{} = event, _result_type = :sync, client, request_retries) do
    case Sentry.Test.maybe_collect(event) do
      :collected ->
        {:ok, ""}

      :not_collecting ->
        send_result =
          event
          |> Envelope.from_event()
          |> Transport.post_envelope(client, request_retries)

        _ = maybe_log_send_result(send_result, event)
        send_result
    end
  end

  defp encode_and_send(%Event{} = event, _result_type = :none, client, _request_retries) do
    case Sentry.Test.maybe_collect(event) do
      :collected ->
        {:ok, ""}

      :not_collecting ->
        :ok = Transport.Sender.send_async(client, event)
        {:ok, ""}
    end
  end

  @spec render_event(Event.t()) :: map()
  def render_event(%Event{} = event) do
    json_library = Config.json_library()

    event
    |> Event.remove_non_payload_keys()
    |> update_if_present(:breadcrumbs, fn bcs -> Enum.map(bcs, &Map.from_struct/1) end)
    |> update_if_present(:sdk, &Map.from_struct/1)
    |> update_if_present(:message, fn message ->
      message = update_in(message.formatted, &String.slice(&1, 0, @max_message_length))
      Map.from_struct(message)
    end)
    |> update_if_present(:request, &(&1 |> Map.from_struct() |> remove_nils()))
    |> update_if_present(:extra, &sanitize_non_jsonable_values(&1, json_library))
    |> update_if_present(:user, &sanitize_non_jsonable_values(&1, json_library))
    |> update_if_present(:tags, &sanitize_non_jsonable_values(&1, json_library))
    |> update_if_present(:exception, fn list -> Enum.map(list, &render_exception/1) end)
    |> update_if_present(:threads, fn list -> Enum.map(list, &render_thread/1) end)
  end

  defp render_exception(%Interfaces.Exception{} = exception) do
    exception
    |> Map.from_struct()
    |> render_or_delete_stacktrace()
    |> update_if_present(:mechanism, &Map.from_struct/1)
  end

  defp render_thread(%Interfaces.Thread{} = thread) do
    thread
    |> Map.from_struct()
    |> render_or_delete_stacktrace()
  end

  # If there are frames, render the stacktrace, otherwise delete it altogether from the map.
  defp render_or_delete_stacktrace(
         %{stacktrace: %Interfaces.Stacktrace{frames: [_ | _]}} = exception_or_thread
       ) do
    exception_or_thread
    |> Map.update!(:stacktrace, &Map.from_struct/1)
    |> update_in([:stacktrace, :frames, Access.all()], &Map.from_struct/1)
  end

  defp render_or_delete_stacktrace(exception_or_thread) do
    Map.delete(exception_or_thread, :stacktrace)
  end

  defp remove_nils(map) when is_map(map) do
    :maps.filter(fn _key, value -> not is_nil(value) end, map)
  end

  defp sanitize_non_jsonable_values(map, json_library) do
    # We update the existing map instead of building a new one from scratch
    # due to performance reasons. See the docs for :maps.map/2.
    Enum.reduce(map, map, fn {key, value}, acc ->
      case sanitize_non_jsonable_value(value, json_library) do
        :unchanged -> acc
        {:changed, value} -> Map.put(acc, key, value)
      end
    end)
  end

  # For performance, skip all the keys that we know for sure are JSON encodable.
  defp sanitize_non_jsonable_value(value, _json_library)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value) do
    :unchanged
  end

  defp sanitize_non_jsonable_value(value, json_library) when is_list(value) do
    {mapped, changed?} =
      Enum.map_reduce(value, _changed? = false, fn value, changed? ->
        case sanitize_non_jsonable_value(value, json_library) do
          :unchanged -> {value, changed?}
          {:changed, value} -> {value, true}
        end
      end)

    if changed? do
      {:changed, mapped}
    else
      :unchanged
    end
  end

  defp sanitize_non_jsonable_value(value, json_library)
       when is_map(value) and not is_struct(value) do
    {:changed, sanitize_non_jsonable_values(value, json_library)}
  end

  defp sanitize_non_jsonable_value(value, json_library) do
    try do
      json_library.encode(value)
    catch
      _type, _reason -> {:changed, inspect(value)}
    else
      {:ok, _encoded} -> :unchanged
      {:error, _reason} -> {:changed, inspect(value)}
    end
  end

  defp update_if_present(map, key, fun) do
    case Map.pop(map, key) do
      {nil, _} -> map
      {value, map} -> Map.put(map, key, fun.(value))
    end
  end

  defp maybe_log_send_result(_send_result, %Event{source: :logger}) do
    :ok
  end

  defp maybe_log_send_result(send_result, _other) do
    message =
      case send_result do
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

        {:error, {status, headers, _body}} ->
          error_header =
            :proplists.get_value("X-Sentry-Error", headers, nil) ||
              :proplists.get_value("x-sentry-error", headers, nil) || ""

          if error_header != "" do
            "Received #{status} from Sentry server: #{error_header}"
          else
            "Received #{status} from Sentry server"
          end

        {:ok, _} ->
          nil
      end

    if message, do: LoggerUtils.log(fn -> ["Failed to send Sentry event. ", message] end)
  end
end
