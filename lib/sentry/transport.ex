defmodule Sentry.Transport do
  @moduledoc false

  # This module is exclusively responsible for POSTing envelopes to Sentry.

  alias Sentry.Config
  alias Sentry.Envelope

  @default_retries [1000, 2000, 4000, 8000]
  @sentry_version 5
  @sentry_client "sentry-elixir/#{Mix.Project.config()[:version]}"

  @spec default_retries() :: [pos_integer(), ...]
  def default_retries do
    @default_retries
  end

  # The "retries" parameter is there for better testing.
  @spec post_envelope(Envelope.t(), module(), [non_neg_integer()]) ::
          {:ok, envelope_id :: String.t()} | {:error, term()}
  def post_envelope(%Envelope{} = envelope, client, retries \\ @default_retries)
      when is_atom(client) and is_list(retries) do
    case Envelope.to_binary(envelope) do
      {:ok, body} ->
        {endpoint, headers} = get_endpoint_and_headers()
        post_envelope_with_retries(client, endpoint, headers, body, retries)

      {:error, reason} ->
        {:error, {:invalid_json, reason}}
    end
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
        {:error, "Sentry server asked us to retry too many times"}

      {:error, _reason} when retries_left != [] ->
        [sleep_interval | retries_left] = retries_left
        Process.sleep(sleep_interval)
        post_envelope_with_retries(client, endpoint, headers, payload, retries_left)

      {:error, reason} ->
        {:error, {:request_failure, reason}}
    end
  end

  defp request(client, endpoint, headers, body) do
    with {:ok, 200, _headers, body} <- client.post(endpoint, headers, body),
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

      {:ok, status, headers, _body} ->
        error_header =
          :proplists.get_value("X-Sentry-Error", headers, nil) ||
            :proplists.get_value("x-sentry-error", headers, nil) || ""

        {:error, "Received #{status} from Sentry server: #{error_header}"}

      {:error, reason} ->
        {:error, reason}
    end
  catch
    kind, data -> {:error, {kind, data, __STACKTRACE__}}
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
end
