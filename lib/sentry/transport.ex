defmodule Sentry.Transport do
  @moduledoc false

  # This module is exclusively responsible for encoding and POSTing envelopes to Sentry.

  alias Sentry.{ClientError, ClientReport, Config, Envelope, LoggerUtils}
  alias Sentry.Transport.RateLimiter

  @default_retries [1000, 2000, 4000, 8000]
  @sentry_version 5
  @sentry_client "sentry-elixir/#{Mix.Project.config()[:version]}"

  @spec default_retries() :: [pos_integer(), ...]
  def default_retries do
    @default_retries
  end

  @doc """
  Encodes the given envelope and POSTs it to Sentry.


  The `retries` parameter is there for better testing. This function also logs
  a warning if there is an error encoding or posting the envelope.
  """
  @spec encode_and_post_envelope(Envelope.t(), module(), [non_neg_integer()]) ::
          {:ok, envelope_id :: String.t()} | {:error, ClientError.t()}
  def encode_and_post_envelope(%Envelope{} = envelope, client, retries \\ @default_retries)
      when is_atom(client) and is_list(retries) do
    result = post_envelope_with_retries(client, envelope, retries)

    _ = maybe_log_send_result(result, envelope.items)
    result
  end

  # Limits are re-applied before every attempt, because a response handled while
  # we slept may have introduced one. Retries recurse with the already-filtered
  # envelope, so each pass only reports the items it newly discards.
  defp post_envelope_with_retries(client, envelope, retries_left) do
    case filter_rate_limited(envelope) do
      {:send, filtered_envelope, discarded_items} ->
        ClientReport.Sender.record_discarded_events(:ratelimit_backoff, discarded_items)

        case Envelope.to_binary(filtered_envelope) do
          {:ok, body} ->
            post_filtered_envelope(client, filtered_envelope, body, retries_left)

          {:error, reason} ->
            {:error, ClientError.new({:invalid_json, reason})}
        end

      {:drop, discarded_items} ->
        ClientReport.Sender.record_discarded_events(:ratelimit_backoff, discarded_items)
        {:error, ClientError.new(:rate_limited)}
    end
  end

  defp post_filtered_envelope(client, %Envelope{items: items} = envelope, body, retries_left) do
    {endpoint, headers} = get_endpoint_and_headers()

    case request(client, endpoint, headers, body) do
      {:ok, id} ->
        {:ok, id}

      {:error, :rate_limited} ->
        ClientReport.Sender.record_discarded_events(:ratelimit_backoff, items)
        {:error, ClientError.new(:rate_limited)}

      {:error, {:envelope_too_large, {status, headers, body}}} ->
        ClientReport.Sender.record_discarded_events(:send_error, items)
        {:error, ClientError.envelope_too_large(status, headers, body)}

      {:error, _reason} when retries_left != [] ->
        [sleep_interval | retries_left] = retries_left
        Process.sleep(sleep_interval)
        post_envelope_with_retries(client, envelope, retries_left)

      {:error, {:http, {status, headers, body}}} ->
        ClientReport.Sender.record_discarded_events(:send_error, items)
        {:error, ClientError.server_error(status, headers, body)}

      {:error, reason} ->
        ClientReport.Sender.record_discarded_events(:send_error, items)
        {:error, ClientError.new(reason)}
    end
  end

  defp filter_rate_limited(%Envelope{items: items} = envelope) do
    if envelope_rate_limited?(items) do
      {:drop, items}
    else
      {discarded_items, retained_items} = Enum.split_with(items, &attachment_rate_limited?/1)

      case retained_items do
        [] -> {:drop, discarded_items}
        _items -> {:send, %Envelope{envelope | items: retained_items}, discarded_items}
      end
    end
  end

  # Attachments are excluded deliberately: a limit on them drops the attachments
  # alone, never the error they belong to.
  defp envelope_rate_limited?(items) do
    RateLimiter.global_rate_limited?() or Enum.any?(items, &whole_envelope_rate_limited?/1)
  end

  defp whole_envelope_rate_limited?(%Sentry.Attachment{}), do: false

  defp whole_envelope_rate_limited?(item) do
    item
    |> Envelope.get_data_category()
    |> RateLimiter.rate_limited_for_category?()
  end

  defp attachment_rate_limited?(item) do
    match?(%Sentry.Attachment{}, item) and
      RateLimiter.rate_limited_for_category?(Envelope.get_data_category(item))
  end

  defp request(client, endpoint, headers, body) do
    with {:ok, 200, _headers, body} <-
           client_post_and_validate_return_value(client, endpoint, headers, body),
         {:ok, json} <- Sentry.JSON.decode(body, Config.json_library()) do
      {:ok, Map.get(json, "id")}
    else
      {:ok, 429, _headers, _body} ->
        {:error, :rate_limited}

      {:ok, 413, headers, body} ->
        {:error, {:envelope_too_large, {413, headers, body}}}

      {:ok, status, headers, body} ->
        {:error, {:http, {status, headers, body}}}

      {:error, reason} ->
        {:error, {:request_failure, reason}}
    end
  catch
    kind, data -> {:error, {kind, data, __STACKTRACE__}}
  end

  defp client_post_and_validate_return_value(client, endpoint, headers, body) do
    case client.post(endpoint, headers, body) do
      {:ok, status, resp_headers, resp_body}
      when is_integer(status) and status in 200..599 and is_list(resp_headers) and
             is_binary(resp_body) ->
        update_rate_limits(resp_headers, status)
        {:ok, status, resp_headers, resp_body}

      {:ok, status, resp_headers, resp_body} ->
        {:error, {:malformed_http_client_response, status, resp_headers, resp_body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp update_rate_limits(headers, status) do
    rate_limits_header = get_header(headers, "x-sentry-rate-limits")

    cond do
      is_binary(rate_limits_header) ->
        # Use categorized rate limits if present
        RateLimiter.update_rate_limits(rate_limits_header)

      status == 429 ->
        # Use global rate limit from Retry-After if no categorized limits are present
        delay_seconds = get_global_delay(headers)
        RateLimiter.update_global_rate_limit(delay_seconds)

      true ->
        :ok
    end
  end

  defp get_global_delay(headers) do
    with timeout when is_binary(timeout) <- get_header(headers, "retry-after"),
         {delay, ""} <- Integer.parse(timeout) do
      delay
    else
      # Per the spec, if Retry-After is missing or malformed, default to 60 seconds
      # https://develop.sentry.dev/sdk/rate-limiting/#stage-1-parse-response-headers
      _ -> 60
    end
  end

  defp get_header(headers, lowercase_name) do
    Enum.find_value(headers, fn
      {header_name, value} when is_binary(header_name) ->
        if String.downcase(header_name) == lowercase_name, do: value

      _other ->
        nil
    end)
  end

  defp get_endpoint_and_headers do
    %Sentry.DSN{} = dsn = Config.dsn()

    auth_query =
      [
        sentry_version: @sentry_version,
        sentry_client: @sentry_client,
        sentry_timestamp: System.system_time(:second),
        sentry_key: dsn.public_key,
        sentry_secret: dsn.secret_key
      ]
      |> Enum.reject(fn {_, value} -> is_nil(value) end)
      |> Enum.map_join(", ", fn {name, value} -> "#{name}=#{value}" end)

    auth_headers = [
      {"User-Agent", @sentry_client},
      {"X-Sentry-Auth", "Sentry " <> auth_query}
    ]

    {dsn.endpoint_uri, auth_headers}
  end

  defp maybe_log_send_result(send_result, events) do
    if Enum.any?(events, &(Map.has_key?(&1, :source) && &1.source == :logger)) do
      :ok
    else
      message =
        case send_result do
          {:error, %ClientError{} = error} ->
            "Failed to send Sentry event. #{Exception.message(error)}"

          {:ok, _} ->
            nil
        end

      if message, do: LoggerUtils.log(fn -> [message] end)
    end
  end
end
