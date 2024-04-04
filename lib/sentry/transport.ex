defmodule Sentry.Transport do
  @moduledoc false

  # This module is exclusively responsible for POSTing envelopes to Sentry.

  alias Sentry.Config
  alias Sentry.Envelope

  @default_retries [1000, 2000, 4000, 8000]

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
        {endpoint, headers} = {Config.envelope_endpoint(), Config.auth_headers()}
        post_envelope_with_retries(client, endpoint, headers, body, retries)

      {:error, reason} ->
        {:error, {:invalid_json, reason}}
    end
  end

  defp post_envelope_with_retries(client, endpoint, headers, payload, retries_left) do
    case request(client, endpoint, headers, payload) do
      {:ok, id} ->
        {:ok, id}

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
end
