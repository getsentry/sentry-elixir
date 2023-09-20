defmodule Sentry.ConfigTest do
  use ExUnit.Case
  import ExUnit.CaptureIO
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

    test "defaults to [\"prod\"]" do
      delete_env(:sentry, :included_environments)
      assert Config.included_environments() == ["prod"]
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
        delete_system_env("SENTRY_ENVIRONMENT")
        Config.environment_name()
      end
    end
  end

  describe "validate_log_level!/0" do
    test "raises for invalid log levels" do
      modify_env(:sentry, log_level: :invalid)

      assert_raise ArgumentError, ":invalid is not a valid :log_level configuration", fn ->
        Config.validate_log_level!()
      end
    end
  end

  describe "assert_dsn_has_no_query_params!/0" do
    test "raises if DSN has query params" do
      modify_env(:sentry, dsn: "https://public:secret@app.getsentry.com/1?send_max_attempts=5")

      assert_raise ArgumentError, ~r/using a Sentry DSN/, fn ->
        Config.assert_dsn_has_no_query_params!()
      end
    end
  end

  describe "warn_for_deprecated_env_vars!/0" do
    test "emits the right warning" do
      delete_env(:sentry, :included_environments)
      modify_system_env(%{"SENTRY_INCLUDED_ENVIRONMENTS" => "test,dev"})

      output =
        capture_io(:stderr, fn ->
          assert :ok = Config.warn_for_deprecated_env_vars!()
        end)

      assert output =~ "setting SENTRY_INCLUDED_ENVIRONMENTS is deprecated"
    end
  end
end
