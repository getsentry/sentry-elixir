defmodule Sentry.Client do
  @sentry_version 5
  quote do
    unquote(@sentry_client "sentry-elixir/#{Mix.Project.config[:version]}")
  end

  def request(method, url, headers, body) do
    case :hackney.request(method, url, headers, body, []) do
      {:ok, 200, _headers, client} ->
        case :hackney.body(client) do
          {:ok, body} ->
            id = Poison.decode!(body)
                  |> Dict.get("id")
            {:ok, id}
          _ -> :error
        end
      _ -> :error
    end
  end

  @doc """
  Generates a Sentry API authorization header.
  """
  @spec authorization_header(String.t, String.t) :: String.t
  def authorization_header(public_key, secret_key) do
    timestamp = unix_timestamp()
    "Sentry sentry_version=#{@sentry_version}, sentry_client=#{@sentry_client}, sentry_timestamp=#{timestamp}, sentry_key=#{public_key}, sentry_secret=#{secret_key}"
  end

  @spec unix_timestamp :: Integer.t
  def unix_timestamp do
    {mega, sec, _micro} = :os.timestamp()
    mega * (1000000 + sec)
  end

  def authorization_headers(public_key, private_key) do
    [
      {"User-Agent", @sentry_client},
      {"X-Sentry-Auth", authorization_header(public_key, private_key)}
    ]
  end
end
