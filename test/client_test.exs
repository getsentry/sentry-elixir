defmodule Sentry.ClientTest do
  use ExUnit.Case, async: true
  alias Sentry.Client
  @sentry_dsn "https://public:secret@app.getsentry.com/1"

  test "authorization" do
    {_endpoint, public_key, private_key} = Client.parse_dsn!("https://public:secret@app.getsentry.com/1")
    assert Client.authorization_header(public_key, private_key) =~ ~r/Sentry sentry_version=5, sentry_client=sentry-elixir\/#{Application.spec(:sentry, :vsn)}, sentry_timestamp=\d{10}, sentry_key=public, sentry_secret=secret/
  end

  test "parning dsn" do
    assert {"https://app.getsentry.com:443/api/1/store/", "public", "secret"} =
      Sentry.Client.parse_dsn!("https://public:secret@app.getsentry.com/1")

    assert {"http://app.getsentry.com:9000/api/1/store/", "public", "secret"} =
      Sentry.Client.parse_dsn!("http://public:secret@app.getsentry.com:9000/1")
  end
end
