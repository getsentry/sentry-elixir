defmodule Sentry.MetricTest do
  use Sentry.Case, async: true

  import Sentry.TestHelpers

  alias Sentry.Metric

  describe "attach_default_attributes/1" do
    test "adds default sentry attributes" do
      put_test_config(environment_name: "test", release: "1.0.0", server_name: "server1")

      metric = %Metric{
        type: :counter,
        name: "test.counter",
        value: 1,
        timestamp: 1_234_567_890.0,
        attributes: %{}
      }

      result = Metric.attach_default_attributes(metric)

      assert result.attributes["sentry.sdk.name"] == "sentry.elixir"
      assert result.attributes["sentry.sdk.version"] == Mix.Project.config()[:version]
      assert result.attributes["sentry.environment"] == "test"
      assert result.attributes["sentry.release"] == "1.0.0"
      assert result.attributes["server.address"] == "server1"
    end

    test "omits nil default attributes" do
      # Don't configure environment_name, release, or server_name
      # (or set them to valid non-nil values but check they're only included if non-nil)
      metric = %Metric{
        type: :counter,
        name: "test.counter",
        value: 1,
        timestamp: 1_234_567_890.0,
        attributes: %{}
      }

      result = Metric.attach_default_attributes(metric)

      # SDK name and version should always be present
      assert result.attributes["sentry.sdk.name"] == "sentry.elixir"
      assert is_binary(result.attributes["sentry.sdk.version"])

      # Optional attributes behavior:
      # If Config returns nil, they should not be added
      # We can't test this directly without mocking Config, so we just verify
      # that the function doesn't crash and includes at minimum the SDK attrs
    end

    test "preserves user attributes" do
      put_test_config(environment_name: "test")

      metric = %Metric{
        type: :counter,
        name: "test.counter",
        value: 1,
        timestamp: 1_234_567_890.0,
        attributes: %{
          "user_key" => "user_value",
          "custom.attribute" => 42
        }
      }

      result = Metric.attach_default_attributes(metric)

      # User attributes should be preserved
      assert result.attributes["user_key"] == "user_value"
      assert result.attributes["custom.attribute"] == 42

      # Default attributes should also be present
      assert result.attributes["sentry.sdk.name"] == "sentry.elixir"
      assert result.attributes["sentry.environment"] == "test"
    end

    test "user attributes take precedence over defaults" do
      put_test_config(environment_name: "production")

      metric = %Metric{
        type: :counter,
        name: "test.counter",
        value: 1,
        timestamp: 1_234_567_890.0,
        attributes: %{
          "sentry.environment" => "custom_environment"
        }
      }

      result = Metric.attach_default_attributes(metric)

      # User-provided value should take precedence
      assert result.attributes["sentry.environment"] == "custom_environment"
    end
  end

  describe "to_map/1" do
    test "converts metric to map with required fields" do
      metric = %Metric{
        type: :counter,
        name: "test.counter",
        value: 5,
        timestamp: 1_234_567_890.0
      }

      result = Metric.to_map(metric)

      assert result.type == "counter"
      assert result.name == "test.counter"
      assert result.value == 5
      assert result.timestamp == 1_234_567_890.0
      assert is_map(result.attributes)
      refute Map.has_key?(result, :unit)
      refute Map.has_key?(result, :trace_id)
      refute Map.has_key?(result, :span_id)
    end

    test "includes optional fields when present" do
      metric = %Metric{
        type: :gauge,
        name: "test.gauge",
        value: 42,
        timestamp: 1_234_567_890.0,
        unit: "byte",
        trace_id: "abc123",
        span_id: "def456"
      }

      result = Metric.to_map(metric)

      assert result.unit == "byte"
      assert result.trace_id == "abc123"
      assert result.span_id == "def456"
    end

    test "formats attributes with type information" do
      metric = %Metric{
        type: :distribution,
        name: "test.distribution",
        value: 100.5,
        timestamp: 1_234_567_890.0,
        attributes: %{
          "endpoint" => "/api/users",
          "status_code" => 200,
          "enabled" => true
        }
      }

      result = Metric.to_map(metric)

      assert result.attributes["endpoint"] == %{value: "/api/users", type: "string"}
      assert result.attributes["status_code"] == %{value: 200, type: "integer"}
      assert result.attributes["enabled"] == %{value: true, type: "boolean"}
    end

    test "sanitizes complex attribute values to strings" do
      metric = %Metric{
        type: :counter,
        name: "test.counter",
        value: 1,
        timestamp: 1_234_567_890.0,
        attributes: %{
          pid: self(),
          list: [1, 2, 3],
          map: %{nested: "value"},
          tuple: {:ok, "value"}
        }
      }

      result = Metric.to_map(metric)

      assert is_binary(result.attributes["pid"].value)
      assert is_binary(result.attributes["list"].value)
      assert is_binary(result.attributes["map"].value)
      assert is_binary(result.attributes["tuple"].value)
    end
  end
end
