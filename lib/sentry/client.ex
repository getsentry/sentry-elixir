defmodule Sentry.Client do
  @moduledoc false

  # A Client is the part of the SDK that is responsible for event creation, running callbacks,
  # and sampling.
  # See https://develop.sentry.dev/sdk/unified-api/#client.

  alias Sentry.{
    CheckIn,
    ClientError,
    ClientReport,
    Config,
    Dedupe,
    Envelope,
    Event,
    Interfaces,
    LogEvent,
    LoggerUtils,
    Options,
    Transaction,
    Transport
  }

  require Logger

  # Max message length per https://github.com/getsentry/sentry/blob/0fcec33ac94ad81a205f86f208072b0f57b39ff4/src/sentry/conf/server.py#L1021
  @max_message_length 8_192

  @spec send_check_in(CheckIn.t(), keyword()) ::
          {:ok, check_in_id :: String.t()} | {:error, ClientError.t()}
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
      |> Transport.encode_and_post_envelope(client, request_retries)

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
    opts = NimbleOptions.validate!(opts, Options.send_event_schema())

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
        ClientReport.Sender.record_discarded_events(:sample_rate, [event])
        :unsampled

      :excluded ->
        :excluded

      {:error, %ClientError{} = error} ->
        {:error, error}
    end
  end

  @spec send_client_report(ClientReport.t()) ::
          {:ok, client_report_id :: String.t()} | {:error, ClientError.t()}
  def send_client_report(%ClientReport{} = client_report) do
    client = Config.client()

    # This is a "private" option, only really used in testing.
    request_retries = Application.get_env(:sentry, :request_retries, Transport.default_retries())

    client_report
    |> Envelope.from_client_report()
    |> Transport.encode_and_post_envelope(client, request_retries)
  end

  @spec send_transaction(Transaction.t(), keyword()) ::
          {:ok, transaction_id :: String.t()}
          | {:error, ClientError.t()}
          | :excluded
  def send_transaction(%Transaction{} = transaction, opts \\ []) do
    opts = NimbleOptions.validate!(opts, Options.send_transaction_schema())

    result_type = Keyword.get_lazy(opts, :result, &Config.send_result/0)
    client = Keyword.get_lazy(opts, :client, &Config.client/0)
    before_send = Keyword.get_lazy(opts, :before_send, &Config.before_send/0)
    after_send_event = Keyword.get_lazy(opts, :after_send_event, &Config.after_send_event/0)

    request_retries =
      Keyword.get_lazy(opts, :request_retries, fn ->
        Application.get_env(:sentry, :request_retries, Transport.default_retries())
      end)

    with {:ok, %Transaction{} = transaction} <- maybe_call_before_send(transaction, before_send) do
      send_result = encode_and_send(transaction, result_type, client, request_retries)
      _ignored = maybe_call_after_send(transaction, send_result, after_send_event)
      send_result
    else
      :excluded ->
        :excluded
    end
  end

  @doc """
  Sends a batch of log events to Sentry.

  Log events are sent asynchronously and do not support callbacks or sampling.
  They are buffered and sent in batches according to the Sentry Logs Protocol.

  Returns `{:ok, envelope_id}` on success or `{:error, reason}` on failure.
  """
  @doc since: "12.0.0"
  @spec send_log_batch([LogEvent.t()]) ::
          {:ok, envelope_id :: String.t()} | {:error, ClientError.t()}
  def send_log_batch([]), do: {:ok, ""}

  def send_log_batch(log_events) when is_list(log_events) do
    case Sentry.Test.maybe_collect_logs(log_events) do
      :collected ->
        {:ok, ""}

      :not_collecting ->
        client = Config.client()

        request_retries =
          Application.get_env(:sentry, :request_retries, Transport.default_retries())

        log_events
        |> Envelope.from_log_events()
        |> Transport.encode_and_post_envelope(client, request_retries)
    end
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

  defp maybe_call_after_send(event_or_transaction, result, callback) do
    message = ":after_send_event must be an anonymous function or a {module, function} tuple"

    case callback do
      function when is_function(function, 2) -> function.(event_or_transaction, result)
      {module, function} -> apply(module, function, [event_or_transaction, result])
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
          |> Transport.encode_and_post_envelope(client, request_retries)

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

  defp encode_and_send(
         %Transaction{} = transaction,
         _result_type = :sync,
         client,
         request_retries
       ) do
    case Sentry.Test.maybe_collect(transaction) do
      :collected ->
        {:ok, ""}

      :not_collecting ->
        send_result =
          transaction
          |> Envelope.from_transaction()
          |> Transport.encode_and_post_envelope(client, request_retries)

        send_result
    end
  end

  defp encode_and_send(
         %Transaction{} = transaction,
         _result_type = :none,
         client,
         _request_retries
       ) do
    case Sentry.Test.maybe_collect(transaction) do
      :collected ->
        {:ok, ""}

      :not_collecting ->
        :ok = Transport.Sender.send_async(client, transaction)
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
    |> update_if_present(:message, &sanitize_message(&1, json_library))
    |> update_if_present(:request, &(&1 |> Map.from_struct() |> remove_nils()))
    |> update_if_present(:extra, &sanitize_non_jsonable_values(&1, json_library))
    |> update_if_present(:user, &sanitize_non_jsonable_values(&1, json_library))
    |> update_if_present(:tags, &sanitize_non_jsonable_values(&1, json_library))
    |> update_if_present(:fingerprint, &sanitize_non_jsonable_values_in_list(&1, json_library))
    |> update_if_present(:exception, fn list -> Enum.map(list, &render_exception/1) end)
    |> update_if_present(:threads, fn list -> Enum.map(list, &render_thread/1) end)
  end

  @spec render_transaction(%Transaction{}) :: map()
  def render_transaction(%Transaction{} = transaction) do
    transaction
    |> Transaction.to_payload()
    |> update_if_present(:sdk, &Map.from_struct/1)
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

  defp sanitize_message(%Interfaces.Message{} = message, json_library) do
    message = update_in(message.formatted, &String.slice(&1, 0, @max_message_length))

    message
    |> Map.from_struct()
    |> sanitize_non_jsonable_values(json_library)
  end

  defp sanitize_non_jsonable_values_in_list(list, json_library) when is_list(list) do
    Enum.map(list, fn elem ->
      case sanitize_non_jsonable_value(elem, json_library) do
        :unchanged -> elem
        {:changed, value} -> value
      end
    end)
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
  # Binaries are a little nasty: something like <<1, 2, 3>> can be encoded in JSON,
  # but other non-printable binaries can't. That's why we skip them here and we
  # let them fall through to when we try to JSON-encode and inspect if that fails.
  defp sanitize_non_jsonable_value(value, _json_library)
       when is_number(value) or is_boolean(value) or is_nil(value) do
    :unchanged
  end

  defp sanitize_non_jsonable_value(value, json_library) when is_list(value) do
    if List.improper?(value) do
      {:changed, inspect(value)}
    else
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
  end

  defp sanitize_non_jsonable_value(value, json_library)
       when is_map(value) and not is_struct(value) do
    {:changed, sanitize_non_jsonable_values(value, json_library)}
  end

  defp sanitize_non_jsonable_value(value, json_library) do
    try do
      Sentry.JSON.encode(value, json_library)
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
end
