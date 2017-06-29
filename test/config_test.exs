defmodule Sentry.ConfigTest do
  use ExUnit.Case
  import Sentry.TestEnvironmentHelper
  alias Sentry.Config

  test "retrieves from application environment" do
    modify_env(:sentry, dsn: "https://public:secret@app.getsentry.com/1")

    assert "https://public:secret@app.getsentry.com/1" == Config.dsn()
  end

  test "retrieves from system environment" do
    modify_system_env(%{"SENTRY_DSN" => "https://public:secret@app.getsentry.com/1"})

    assert "https://public:secret@app.getsentry.com/1" == Config.dsn()
  end

  test "retrieves from DSN query string" do
    modify_env(:sentry, dsn: "https://public:super_secret@app.getsentry.com/2?server_name=my_server")

    assert "my_server" == Config.server_name()
  end
end
