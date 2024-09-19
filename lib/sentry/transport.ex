defmodule Sentry.Transport do
  @moduledoc false

  # This module is exclusively responsible for encoding and POSTing envelopes to Sentry.

  alias Sentry.{ClientError, Config, Envelope, LoggerUtils}

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
    result =
      case Envelope.to_binary(envelope) do
        {:ok, body} ->
          {endpoint, headers} = get_endpoint_and_headers()
          post_envelope_with_retries(client, endpoint, headers, body, retries)

        {:error, reason} ->
          {:error, ClientError.new({:invalid_json, reason})}
      end

    _ = maybe_log_send_result(result, envelope.items)

    result
  end

  defp post_envelope_with_retries(client, endpoint, headers, payload, retries_left) do
    case request(client, endpoint, headers, payload) do
      {:ok, id} ->
        {:ok, id}

      # If Sentry gives us a Retry-After header, we listen to that instead of our
      # own retry.
      {:retry_after, delay_ms} when retries_left != [] ->
        Process.sleep(delay_ms)
        post_envelope_with_retries(client, endpoint, headers, payload, tl(retries_left))

      {:retry_after, _delay_ms} ->
        {:error, ClientError.new(:too_many_retries)}

      {:error, _reason} when retries_left != [] ->
        [sleep_interval | retries_left] = retries_left
        Process.sleep(sleep_interval)
        post_envelope_with_retries(client, endpoint, headers, payload, retries_left)

      {:error, {:http, {status, headers, body}}} ->
        {:error, ClientError.server_error(status, headers, body)}

      {:error, reason} ->
        {:error, ClientError.new(reason)}
    end
  end

  defp request(client, endpoint, headers, body) do
    with {:ok, 200, _headers, body} <-
           client_post_and_validate_return_value(client, endpoint, headers, body),
         {:ok, json} <- Config.json_library().decode(body) do
      {:ok, Map.get(json, "id")}
    else
      {:ok, 429, headers, _body} ->
        delay_ms =
          with timeout when is_binary(timeout) <-
                 :proplists.get_value("Retry-After", headers, nil),
               {delay_s, ""} <- Integer.parse(timeout) do
            delay_s * 1000
          else
            _ ->
              # https://develop.sentry.dev/sdk/rate-limiting/#stage-1-parse-response-headers
              60_000
          end

        {:retry_after, delay_ms}

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
        {:ok, status, resp_headers, resp_body}

      {:ok, status, resp_headers, resp_body} ->
        {:error, {:malformed_http_client_response, status, resp_headers, resp_body}}

      {:error, reason} ->
        {:error, reason}
    end
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

  def maybe_log_send_result(send_result, events) do
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
