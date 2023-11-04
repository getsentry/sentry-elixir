defmodule Sentry.ConfigTest do
  use ExUnit.Case, async: false

  import Sentry.TestEnvironmentHelper

  alias Sentry.Config

  setup do
    modify_system_env(%{"SENTRY_ENVIRONMENT" => "test"})
    :ok
  end

  describe "validate!/0" do
    test ":dsn from option" do
      dsn = "https://public:secret@app.getsentry.com/1"
      assert Config.validate!(dsn: dsn)[:dsn] == dsn
    end

    test ":dsn from system environment" do
      dsn = "https://public:secret@app.getsentry.com/1"
      modify_system_env(%{"SENTRY_DSN" => dsn})
      assert Config.validate!([])[:dsn] == dsn
    end

    test "invalid :dsn with query params" do
      message = ~r"using a Sentry DSN with query parameters is not supported"

      assert_raise ArgumentError, message, fn ->
        Config.validate!(dsn: "https://public:secret@app.getsentry.com/1?send_max_attempts=5")
      end
    end

    test "invalid :dsn" do
      assert_raise ArgumentError, ~r/invalid value for :dsn option/, fn ->
        Config.validate!(dsn: :not_a_string)
      end
    end

    test ":release from option" do
      assert Config.validate!(release: "1.0.0")[:release] == "1.0.0"
    end

    test ":release from system env" do
      modify_system_env(%{"SENTRY_RELEASE" => "1.0.0"})
      assert Config.validate!([])[:release] == "1.0.0"
    end

    test ":log_level" do
      assert_raise ArgumentError, ~r/invalid value for :log_level option/, fn ->
        Config.validate!(log_level: :invalid)
      end
    end

    test ":source_code_path_pattern" do
      assert Config.validate!(source_code_path_pattern: "*.ex")[:source_code_path_pattern] ==
               "*.ex"

      assert Config.validate!([])[:source_code_path_pattern] == "**/*.ex"

      assert_raise ArgumentError, ~r/invalid value for :source_code_path_pattern option/, fn ->
        Config.validate!(source_code_path_pattern: :invalid)
      end
    end

    test ":source_code_exclude_patterns" do
      assert Config.validate!(source_code_exclude_patterns: [])[:source_code_exclude_patterns] ==
               []

      assert Config.validate!([])[:source_code_exclude_patterns] == [
               ~r"/_build/",
               ~r"/deps/",
               ~r"/priv/",
               ~r"/test/"
             ]

      message = ~r/invalid list in :source_code_exclude_patterns option/

      assert_raise ArgumentError, message, fn ->
        Config.validate!(source_code_exclude_patterns: ["foo"])
      end
    end

    test ":included_environments" do
      assert Config.validate!(included_environments: [:test, "dev"])[:included_environments] ==
               ["test", "dev"]

      assert Config.validate!([])[:included_environments] == :all

      assert_raise ArgumentError, ~r/invalid value for :included_environments/, fn ->
        Config.validate!(included_environments: "not a list")
      end
    end

    test ":environment_name from option" do
      assert Config.validate!(environment_name: "test")[:environment_name] == "test"
    end

    test ":environment_name from system env" do
      modify_system_env(%{"SENTRY_ENVIRONMENT" => "my_env"})
      assert Config.validate!([])[:environment_name] == "my_env"
    end

    test ":environment_name is required" do
      delete_system_env("SENTRY_ENVIRONMENT")

      assert_raise ArgumentError, ~r/:environment_name must be set/, fn ->
        Config.validate!([])
      end
    end

    test ":sample_rate" do
      assert Config.validate!(sample_rate: 0.5)[:sample_rate] == 0.5

      assert_raise ArgumentError, ~r/invalid value for :sample_rate option/, fn ->
        Config.validate!(sample_rate: 2.0)
      end
    end

    test ":json_library" do
      assert Config.validate!(json_library: Jason)[:json_library] == Jason

      # Default
      assert Config.validate!([])[:json_library] == Jason

      assert_raise ArgumentError, ~r/invalid value for :json_library option/, fn ->
        Config.validate!(json_library: URI)
      end
    end

    test ":before_send_event" do
      assert Config.validate!(before_send_event: {MyMod, :my_fun})[:before_send_event] ==
               {MyMod, :my_fun}

      fun = & &1
      assert Config.validate!(before_send_event: fun)[:before_send_event] == fun

      assert_raise ArgumentError, ~r/invalid value for :before_send_event option/, fn ->
        Config.validate!(before_send_event: :not_a_function)
      end
    end

    test ":after_send_event" do
      assert Config.validate!(after_send_event: {MyMod, :my_fun})[:after_send_event] ==
               {MyMod, :my_fun}

      fun = fn _event, _result -> :ok end
      assert Config.validate!(after_send_event: fun)[:after_send_event] == fun

      assert_raise ArgumentError, ~r/invalid value for :after_send_event option/, fn ->
        Config.validate!(after_send_event: :not_a_function)
      end
    end
  end

  describe "put_config/2" do
    test "updates the configuration" do
      dsn = "https://public:secret@app.getsentry.com/1"
      config = Config.validate!(dsn: dsn)
      Config.persist(config)

      assert Config.dsn() == dsn

      new_dsn = "https://public:secret@app.getsentry.com/2"
      assert :ok = Config.put_config(:dsn, new_dsn)

      assert Config.dsn() == new_dsn
    end

    test "validates the given key" do
      assert_raise ArgumentError, ~r/unknown options \[:non_existing\]/, fn ->
        Config.put_config(:non_existing, "value")
      end
    end
  end
end
