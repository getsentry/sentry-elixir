defmodule Sentry.ConfigTest do
  use Sentry.Case, async: false

  alias Sentry.Config

  describe "validate!/0" do
    test ":dsn from option" do
      assert %Sentry.DSN{} =
               dsn = Config.validate!(dsn: "https://public:secret@app.getsentry.com/1")[:dsn]

      assert dsn.endpoint_uri == "https://app.getsentry.com/api/1/envelope/"
      assert dsn.public_key == "public"
      assert dsn.secret_key == "secret"
      assert dsn.original_dsn == "https://public:secret@app.getsentry.com/1"

      assert Config.validate!(dsn: nil)[:dsn] == nil
    end

    test ":dsn from system environment" do
      with_system_env("SENTRY_DSN", "https://public:secret@app.getsentry.com/1", fn ->
        assert %Sentry.DSN{} = dsn = Config.validate!([])[:dsn]
        assert dsn.endpoint_uri == "https://app.getsentry.com/api/1/envelope/"
        assert dsn.public_key == "public"
        assert dsn.secret_key == "secret"
        assert dsn.original_dsn == "https://public:secret@app.getsentry.com/1"
      end)
    end

    test "invalid :dsn with query params" do
      message = ~r"using a Sentry DSN with query parameters is not supported"

      assert_raise ArgumentError, message, fn ->
        Config.validate!(dsn: "https://public:secret@app.getsentry.com/1?send_max_attempts=5")
      end
    end

    test "invalid :dsn" do
      # Not a string.
      assert_raise ArgumentError, ~r/invalid value for :dsn option/, fn ->
        Config.validate!(dsn: :not_a_string)
      end

      # Project ID is missing.
      assert_raise ArgumentError, ~r/missing project ID at the end of the DSN URI/, fn ->
        Config.validate!(dsn: "https://public:secret@app.getsentry.com")
      end

      # Project ID is not an integer.
      assert_raise ArgumentError, ~r/DSN path to end with an integer project ID/, fn ->
        Config.validate!(dsn: "https://public:secret@app.getsentry.com/not-an-int")
      end

      # Userinfo is missing.
      for dsn <- ["https://app.getsentry.com/1", "https://@app.getsentry.com/1"] do
        assert_raise ArgumentError, ~r/missing user info in the DSN URI/, fn ->
          Config.validate!(dsn: dsn)
        end
      end
    end

    test ":source_code_map_path from option" do
      assert Config.validate!()[:source_code_map_path] == nil

      assert Config.validate!(source_code_map_path: "test.map")[:source_code_map_path] ==
               "test.map"
    end

    test ":release from option" do
      assert Config.validate!(release: "1.0.0")[:release] == "1.0.0"
    end

    test ":release from system env" do
      with_system_env("SENTRY_RELEASE", "1.0.0", fn ->
        assert Config.validate!([])[:release] == "1.0.0"
      end)
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

    # TODO: remove me on v11.0.0. :included_environments has been deprecated in v10.0.0.
    test ":included_environments" do
      output =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          assert Config.validate!(included_environments: [:test, "dev"])[:included_environments] ==
                   ["test", "dev"]

          assert Config.validate!([])[:included_environments] == :all

          assert_raise ArgumentError, ~r/invalid value for :included_environments/, fn ->
            Config.validate!(included_environments: "not a list")
          end
        end)

      assert output =~ ":included_environments option is deprecated"
    end

    test ":environment_name from option" do
      assert Config.validate!(environment_name: "test")[:environment_name] == "test"
    end

    test ":environment_name from system env" do
      with_system_env("SENTRY_ENVIRONMENT", "my_env", fn ->
        assert Config.validate!([])[:environment_name] == "my_env"
      end)
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
        Config.validate!(json_library: Atom)
      end

      assert_raise ArgumentError, ~r/invalid value for :json_library option/, fn ->
        Config.validate!(json_library: nil)
      end

      assert_raise ArgumentError, ~r/invalid value for :json_library option/, fn ->
        Config.validate!(json_library: "not a module")
      end
    end

    test ":before_send" do
      assert Config.validate!(before_send: {MyMod, :my_fun})[:before_send] ==
               {MyMod, :my_fun}

      fun = & &1
      assert Config.validate!(before_send: fun)[:before_send] == fun

      assert_raise ArgumentError, ~r/invalid value for :before_send option/, fn ->
        Config.validate!(before_send: :not_a_function)
      end
    end

    # TODO: Remove in v11.0.0, we deprecated it in v10.0.0.
    test ":before_send_event" do
      assert ExUnit.CaptureIO.capture_io(:stderr, fn ->
               assert Config.validate!(before_send_event: {MyMod, :my_fun})[:before_send] ==
                        {MyMod, :my_fun}
             end) =~ ":before_send_event option is deprecated. Use :before_send instead."

      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        assert_raise ArgumentError, ~r/you cannot configure both :before_send and/, fn ->
          assert Config.validate!(
                   before_send_event: {MyMod, :my_fun},
                   before_send: {MyMod, :my_fun}
                 )
        end
      end)
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
      dsn_before = :persistent_term.get({:sentry_config, :dsn}, :__not_set__)

      on_exit(fn ->
        case dsn_before do
          :__not_set__ -> :persistent_term.erase({:sentry_config, :dsn})
          other -> :persistent_term.put({:sentry_config, :dsn}, other)
        end
      end)

      new_dsn = "https://public:secret@app.getsentry.com/2"
      assert :ok = Config.put_config(:dsn, new_dsn)

      assert %Sentry.DSN{
               original_dsn: ^new_dsn,
               endpoint_uri: "https://app.getsentry.com/api/2/envelope/",
               public_key: "public",
               secret_key: "secret"
             } = Config.dsn()
    end

    test "validates the given key" do
      assert_raise ArgumentError, ~r/unknown option :non_existing/, fn ->
        Config.put_config(:non_existing, "value")
      end
    end
  end

  defp with_system_env(key, value, fun) when is_function(fun, 0) do
    original_env = System.fetch_env(key)
    System.put_env(key, value)

    try do
      fun.()
    after
      case original_env do
        {:ok, original_value} -> System.put_env(key, original_value)
        :error -> System.delete_env(key)
      end
    end
  end
end
