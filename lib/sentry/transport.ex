defmodule Sentry.Transport do
  @moduledoc false

  # This module is exclusively responsible for POSTing envelopes to Sentry.

  alias Sentry.Config
  alias Sentry.Envelope

  @default_retries [1000, 2000, 4000, 8000]
  @sentry_version 5
  @sentry_client "sentry-elixir/#{Mix.Project.config()[:version]}"

  # The "retries" parameter is there for better testing.
  @spec post_envelope(Envelope.t(), [non_neg_integer()]) :: :ok
  def post_envelope(%Envelope{} = envelope, retries \\ @default_retries) when is_list(retries) do
    with {:ok, body} <- Envelope.to_binary(envelope),
         {:ok, endpoint, headers} <- get_endpoint_and_headers() do
      post_envelope_with_retries(endpoint, headers, body, retries)
    else
      {:error, _reason} = error ->
        error
    end
  end

  defp post_envelope_with_retries(endpoint, headers, payload, retries_left) do
    case request(endpoint, headers, payload) do
      {:ok, id} ->
        {:ok, id}

      {:error, _reason} when retries_left != [] ->
        [sleep_interval | retries_left] = retries_left
        Process.sleep(sleep_interval)
        post_envelope_with_retries(endpoint, headers, payload, retries_left)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp request(endpoint, headers, body) do
    with {:ok, 200, _headers, body} <- Config.client().post(endpoint, headers, body),
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

  defp get_endpoint_and_headers do
    case get_dsn() do
      {endpoint, public_key, secret_key} ->
        {:ok, endpoint, authorization_headers(public_key, secret_key)}

      {:error, :invalid_dsn} ->
        {:error, :invalid_dsn}
    end
  end

  defp get_dsn do
    with dsn when is_binary(dsn) <- Config.dsn(),
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

  defp keys_from_userinfo(userinfo) do
    case String.split(userinfo, ":", parts: 2) do
      [public, secret] -> [public, secret]
      [public] -> [public, nil]
      _ -> :error
    end
  end

  defp authorization_headers(public_key, secret_key) do
    auth_query =
      [
        sentry_version: @sentry_version,
        sentry_client: @sentry_client,
        sentry_timestamp: System.system_time(:second),
        sentry_key: public_key,
        sentry_secret: secret_key
      ]
      |> Enum.reject(fn {_, value} -> is_nil(value) end)
      |> Enum.map_join(", ", fn {name, value} -> "#{name}=#{value}" end)

    [
      {"User-Agent", @sentry_client},
      {"X-Sentry-Auth", "Sentry " <> auth_query}
    ]
  end
end
