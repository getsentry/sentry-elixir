defmodule Sentry.ConfigTest do
  use ExUnit.Case
  import Sentry.TestEnvironmentHelper
  alias Sentry.Config

  describe "dsn/0" do
    test "retrieves from application environment" do
      dsn = "https://public:secret@app.getsentry.com/1"
      modify_env(:sentry, dsn: dsn)
      assert Config.dsn() == dsn
    end

    test "retrieves from system environment" do
      dsn = "https://public:secret@app.getsentry.com/1"
      modify_system_env(%{"SENTRY_DSN" => dsn})
      assert Config.dsn() == dsn
    end

    test "sets application env if found in system env" do
      dsn = "https://public:secret@app.getsentry.com/1"
      modify_system_env(%{"SENTRY_DSN" => dsn})

      assert Config.dsn() == dsn
      assert Application.get_env(:sentry, :dsn) == dsn
    end
  end

  describe "source_code_path_pattern/0" do
    test "returns default when not configured" do
      assert Config.source_code_path_pattern() == "**/*.ex"
    end
  end

  describe "included_environments/0" do
    test "retrieves from app env" do
      modify_env(:sentry, included_environments: [:test, :dev])
      assert Config.included_environments() == ["test", "dev"]
    end
  end

  describe "environment_name/0" do
    test "retrieves from app env" do
      modify_env(:sentry, environment_name: "test")
      assert Config.environment_name() == "test"
    end

    test "retrieves from system env" do
      modify_env(:sentry, environment_name: nil)
      modify_system_env(%{"SENTRY_ENVIRONMENT" => "test"})
      assert Config.environment_name() == "test"
    end

    test "raises if not set" do
      assert_raise RuntimeError, ~r/:environment_name must be set/, fn ->
        modify_env(:sentry, environment_name: nil)
        Config.environment_name()
      end
    end
  end
end
