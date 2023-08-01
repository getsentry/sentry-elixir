defmodule Sentry.ConfigTest do
  use ExUnit.Case
  import Sentry.TestEnvironmentHelper
  alias Sentry.Config

  test "retrieves from application environment" do
    dsn = "https://public:secret@app.getsentry.com/1"
    modify_env(:sentry, dsn: dsn)
    assert dsn == Config.dsn()
  end

  test "retrieves from system environment" do
    dsn = "https://public:secret@app.getsentry.com/1"
    modify_system_env(%{"SENTRY_DSN" => dsn})

    assert dsn == Config.dsn()
  end

  test "sets application env if found in system env" do
    dsn = "https://public:secret@app.getsentry.com/1"
    modify_system_env(%{"SENTRY_DSN" => dsn})

    assert Config.dsn() == dsn
    assert Application.get_env(:sentry, :dsn) == dsn
  end

  describe "source_code_path_pattern" do
    test "returns default when not configured" do
      assert "**/*.ex" == Config.source_code_path_pattern()
    end
  end

  describe "included_environments" do
    test "retrieves from app env" do
      modify_env(:sentry, included_environments: [:test, :dev])
      assert [:test, :dev] == Config.included_environments()
    end
  end
end
