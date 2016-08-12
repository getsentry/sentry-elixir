defmodule Sentry.ClientTest do
  use ExUnit.Case
  alias Sentry.Client

  test "authorization" do
    {_endpoint, public_key, private_key} = Client.parse_dsn!("https://public:secret@app.getsentry.com/1")
    assert Client.authorization_header(public_key, private_key) =~ ~r/Sentry sentry_version=5, sentry_client=sentry-elixir\/0.0.5, sentry_timestamp=\d+, sentry_key=public, sentry_secret=secret/
  end
end
