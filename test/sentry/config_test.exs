defmodule Sentry.ConfigTest do
  use Sentry.Case, async: false

  import Sentry.TestHelpers

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
      assert Config.validate!([])[:source_code_exclude_patterns] == nil

      regex = ~r/foo/
      config = [source_code_exclude_patterns: [regex]]
      assert Config.validate!(config)[:source_code_exclude_patterns] == [regex]

      config = [source_code_exclude_patterns: ["foo", "bar/baz"]]
      assert Config.validate!(config)[:source_code_exclude_patterns] == ["foo", "bar/baz"]

      config = [source_code_exclude_patterns: [~r/foo/, "bar"]]
      [regex, string] = Config.validate!(config)[:source_code_exclude_patterns]
      assert regex.source == "foo"
      assert string == "bar"

      message = ~r/invalid regex pattern/

      assert_raise ArgumentError, message, fn ->
        Config.validate!(source_code_exclude_patterns: ["[invalid"])
      end

      message = ~r/expected a Regex or a string pattern/

      assert_raise ArgumentError, message, fn ->
        Config.validate!(source_code_exclude_patterns: [:atom])
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

    test ":environment_name set to default" do
      previous_value = Application.get_env(:sentry, :environment_name)
      Application.delete_env(:sentry, :environment_name)

      on_exit(fn ->
        Application.put_env(:sentry, :environment_name, previous_value)
        assert previous_value === Application.get_env(:sentry, :environment_name)
      end)

      assert Config.validate!()[:environment_name] == "production"
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

    test ":traces_sample_rate" do
      assert Config.validate!([])[:traces_sample_rate] == nil

      assert Config.validate!(traces_sample_rate: nil)[:traces_sample_rate] == nil
      assert Config.validate!(traces_sample_rate: 0.0)[:traces_sample_rate] == 0.0
      assert Config.validate!(traces_sample_rate: 0.5)[:traces_sample_rate] == 0.5
      assert Config.validate!(traces_sample_rate: 1.0)[:traces_sample_rate] == 1.0

      assert_raise ArgumentError, ~r/invalid value for :traces_sample_rate option/, fn ->
        Config.validate!(traces_sample_rate: 2.0)
      end
    end

    test ":json_library" do
      assert Config.validate!(json_library: Jason)[:json_library] == Jason

      # Default
      if Version.match?(System.version(), "~> 1.18") do
        assert Config.validate!([])[:json_library] == JSON
      else
        assert Config.validate!([])[:json_library] == Jason
      end

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

    test ":before_send_log" do
      assert Config.validate!(before_send_log: {MyMod, :my_fun})[:before_send_log] ==
               {MyMod, :my_fun}

      fun = & &1
      assert Config.validate!(before_send_log: fun)[:before_send_log] == fun

      assert_raise ArgumentError, ~r/invalid value for :before_send_log option/, fn ->
        Config.validate!(before_send_log: :not_a_function)
      end
    end

    test "deprecated hackney options do not warn when not explicitly configured" do
      output =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          # Only configure non-hackney options
          Config.validate!(dsn: "https://public:secret@app.getsentry.com/1")
        end)

      refute output =~ "hackney"
    end

    test "deprecated hackney options warn when explicitly configured" do
      output =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          Config.validate!(hackney_opts: [pool: :my_pool])
        end)

      assert output =~ ":hackney_opts option is deprecated"
      assert output =~ "Use Finch as the default HTTP client instead"

      output =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          Config.validate!(hackney_pool_timeout: 10_000)
        end)

      assert output =~ ":hackney_pool_timeout option is deprecated"

      output =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          Config.validate!(hackney_pool_max_connections: 100)
        end)

      assert output =~ ":hackney_pool_max_connections option is deprecated"
    end

    test ":telemetry_buffer_capacities" do
      # Default value is empty map
      assert Config.validate!([])[:telemetry_buffer_capacities] == %{}

      # Custom value with valid categories
      capacities = %{log: 2000}

      assert Config.validate!(telemetry_buffer_capacities: capacities)[
               :telemetry_buffer_capacities
             ] == capacities

      # Invalid: wrong category key
      assert_raise ArgumentError, ~r/telemetry_buffer_capacities/, fn ->
        Config.validate!(telemetry_buffer_capacities: %{invalid: 100})
      end

      # Invalid: not a positive integer value
      assert_raise ArgumentError, ~r/telemetry_buffer_capacities/, fn ->
        Config.validate!(telemetry_buffer_capacities: %{log: 0})
      end
    end

    test ":namespace with valid resolver" do
      assert Config.validate!(namespace: {Sentry.Config, :namespace})[:namespace] ==
               {Sentry.Config, :namespace}
    end

    test ":namespace with non-existent module" do
      assert_raise ArgumentError, ~r/could not be loaded/, fn ->
        Config.validate!(namespace: {NonExistentModule, :resolve})
      end
    end

    test ":namespace with module that doesn't export the function" do
      assert_raise ArgumentError, ~r/is not exported/, fn ->
        Config.validate!(namespace: {Sentry.Config, :non_existent_function})
      end
    end

    test ":namespace with invalid value" do
      assert_raise ArgumentError, ~r/invalid value for :namespace option/, fn ->
        Config.validate!(namespace: :not_a_tuple)
      end
    end

    test ":telemetry_scheduler_weights" do
      # Default value is empty map
      assert Config.validate!([])[:telemetry_scheduler_weights] == %{}

      # Custom value with valid priorities
      weights = %{low: 5}

      assert Config.validate!(telemetry_scheduler_weights: weights)[:telemetry_scheduler_weights] ==
               weights

      # Invalid: wrong priority key
      assert_raise ArgumentError, ~r/telemetry_scheduler_weights/, fn ->
        Config.validate!(telemetry_scheduler_weights: %{invalid: 5})
      end

      # Invalid: not a positive integer value
      assert_raise ArgumentError, ~r/telemetry_scheduler_weights/, fn ->
        Config.validate!(telemetry_scheduler_weights: %{low: 0})
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

  describe ":enable_metrics" do
    test "defaults to true" do
      config = Config.validate!([])
      assert config[:enable_metrics] == true
    end

    test "can be set to false" do
      config = Config.validate!(enable_metrics: false)
      assert config[:enable_metrics] == false
    end
  end

  describe ":before_send_metric" do
    test "accepts a function callback" do
      callback = fn metric -> metric end
      config = Config.validate!(before_send_metric: callback)
      assert is_function(config[:before_send_metric], 1)
    end

    test "accepts a {module, function} tuple" do
      config = Config.validate!(before_send_metric: {MyModule, :my_function})
      assert config[:before_send_metric] == {MyModule, :my_function}
    end

    test "defaults to nil" do
      config = Config.validate!([])
      assert config[:before_send_metric] == nil
    end
  end

  describe ":org_id" do
    test "defaults to nil" do
      assert Config.validate!([])[:org_id] == nil
    end

    test "accepts a non-empty string" do
      assert Config.validate!(org_id: "1234567")[:org_id] == "1234567"
    end

    test "accepts nil explicitly" do
      assert Config.validate!(org_id: nil)[:org_id] == nil
    end

    test "rejects an empty string" do
      assert_raise ArgumentError, ~r/expected :org_id to be a non-empty string or nil/, fn ->
        Config.validate!(org_id: "")
      end
    end

    test "rejects a non-string value" do
      assert_raise ArgumentError, ~r/invalid value for :org_id option/, fn ->
        Config.validate!(org_id: 1234)
      end
    end
  end

  describe "effective_org_id/0" do
    test "returns nil when no org_id is configured and DSN has no org ID" do
      put_test_config(dsn: "https://public:secret@app.getsentry.com/1", org_id: nil)
      assert Config.effective_org_id() == nil
    end

    test "returns explicit org_id when configured" do
      put_test_config(org_id: "9876543")
      assert Config.effective_org_id() == "9876543"
    end

    test "falls back to org ID extracted from DSN host" do
      put_test_config(dsn: "https://public@o1234567.ingest.sentry.io/123", org_id: nil)
      assert Config.effective_org_id() == "1234567"
    end

    test "explicit org_id takes precedence over DSN-derived org ID" do
      put_test_config(dsn: "https://public@o1234567.ingest.sentry.io/123", org_id: "9999999")
      assert Config.effective_org_id() == "9999999"
    end
  end

  describe ":strict_trace_continuation" do
    test "defaults to false" do
      assert Config.validate!([])[:strict_trace_continuation] == false
    end

    test "accepts true" do
      assert Config.validate!(strict_trace_continuation: true)[:strict_trace_continuation] == true
    end

    test "accepts false" do
      assert Config.validate!(strict_trace_continuation: false)[:strict_trace_continuation] == false
    end
  end
end
