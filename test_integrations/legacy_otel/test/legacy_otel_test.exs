defmodule LegacyOtelTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  describe "OpenTelemetry version compatibility" do
    test "older OpenTelemetry versions are detected as incompatible" do
      refute Sentry.OpenTelemetry.VersionChecker.tracing_compatible?()

      assert {:error, {:incompatible_versions, errors}} =
        Sentry.OpenTelemetry.VersionChecker.check_compatibility()

      assert length(errors) > 0
      error_deps = Enum.map(errors, fn {dep, _reason} -> dep end)

      expected_deps = [:opentelemetry, :opentelemetry_api, :opentelemetry_exporter, :opentelemetry_semantic_conventions]
      assert Enum.any?(expected_deps, fn dep -> dep in error_deps end)
    end

    test "Sentry OpenTelemetry modules are not defined with older versions" do
      refute Code.ensure_loaded?(Sentry.OpenTelemetry.SpanProcessor)
      refute Code.ensure_loaded?(Sentry.OpenTelemetry.Sampler)
      refute Code.ensure_loaded?(Sentry.OpenTelemetry.SpanRecord)
    end

    test "LegacyOtel.test_sentry_otel_integration/0 returns expected results" do
      result = LegacyOtel.test_sentry_otel_integration()

      assert is_map(result)
      assert Map.has_key?(result, :span_processor_defined)
      assert Map.has_key?(result, :sampler_defined)
      assert Map.has_key?(result, :span_record_defined)
      assert Map.has_key?(result, :version_compatible)
      assert Map.has_key?(result, :loaded_versions)

      refute result.span_processor_defined
      refute result.sampler_defined
      refute result.span_record_defined
      refute result.version_compatible

      assert is_map(result.loaded_versions)
      assert Map.has_key?(result.loaded_versions, :opentelemetry)
    end

    test "loaded OpenTelemetry versions are older than required" do
      versions = LegacyOtel.get_otel_versions()

      assert Map.get(versions, :opentelemetry) == "1.3.1"
      assert Map.get(versions, :opentelemetry_api) == "1.2.2"
      assert Map.get(versions, :opentelemetry_exporter) == "1.4.1"
      assert Map.get(versions, :opentelemetry_semantic_conventions) == "0.2.0"
    end
  end

  describe "Sentry configuration with older OpenTelemetry" do
    test "tracing should be disabled in Sentry config" do
      refute Sentry.Config.tracing?
    end

    test "Config.validate! warns when traces_sample_rate is set but dependencies are not satisfied" do
      config = [
        dsn: "https://public@sentry.example.com/1",
        traces_sample_rate: 0.5
      ]

      log_output = capture_log(fn ->
        validated_config = Sentry.Config.validate!(config)

        assert Keyword.get(validated_config, :traces_sample_rate) == 0.5
        dsn = Keyword.get(validated_config, :dsn)
        assert dsn.original_dsn == "https://public@sentry.example.com/1"
      end)

      assert log_output =~ "Sentry tracing is configured with traces_sample_rate: 0.5"
      assert log_output =~ "but the required OpenTelemetry dependencies are not satisfied"
      assert log_output =~ "Tracing will be disabled"
      assert log_output =~ "opentelemetry (>= 1.5.0)"
      assert log_output =~ "opentelemetry_api (>= 1.4.0)"
      assert log_output =~ "opentelemetry_exporter (>= 1.0.0)"
      assert log_output =~ "opentelemetry_semantic_conventions (>= 1.27.0)"
    end

    test "Config.validate! does not warn when traces_sample_rate is nil" do
      config = [
        dsn: "https://public@sentry.example.com/1",
        traces_sample_rate: nil
      ]

      log_output = capture_log(fn ->
        validated_config = Sentry.Config.validate!(config)

        assert Keyword.get(validated_config, :traces_sample_rate) == nil
        dsn = Keyword.get(validated_config, :dsn)
        assert dsn.original_dsn == "https://public@sentry.example.com/1"
      end)

      refute log_output =~ "Sentry tracing is configured"
      refute log_output =~ "OpenTelemetry dependencies are not satisfied"
    end

    test "Config.validate! does not warn when traces_sample_rate is not set" do
      config = [
        dsn: "https://public@sentry.example.com/1"
      ]

      log_output = capture_log(fn ->
        validated_config = Sentry.Config.validate!(config)

        assert Keyword.get(validated_config, :traces_sample_rate) == nil
        dsn = Keyword.get(validated_config, :dsn)
        assert dsn.original_dsn == "https://public@sentry.example.com/1"
      end)

      refute log_output =~ "Sentry tracing is configured"
      refute log_output =~ "OpenTelemetry dependencies are not satisfied"
    end
  end
end
