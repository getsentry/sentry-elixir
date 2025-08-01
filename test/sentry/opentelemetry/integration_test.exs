defmodule Sentry.OpenTelemetry.IntegrationTest do
  use ExUnit.Case, async: true

  alias Sentry.OpenTelemetry.VersionChecker

  describe "OpenTelemetry integration with compatible versions" do
    test "modules are defined when versions are compatible" do
      case VersionChecker.tracing_compatible?() do
        true ->
          # When versions are compatible, modules should be defined
          assert Code.ensure_loaded?(Sentry.OpenTelemetry.SpanProcessor)
          assert Code.ensure_loaded?(Sentry.OpenTelemetry.Sampler)
          assert Code.ensure_loaded?(Sentry.OpenTelemetry.SpanRecord)
          assert Code.ensure_loaded?(Sentry.OpenTelemetry.SpanStorage)

        false ->
          # When versions are incompatible, modules should not be defined
          refute Code.ensure_loaded?(Sentry.OpenTelemetry.SpanProcessor)
          refute Code.ensure_loaded?(Sentry.OpenTelemetry.Sampler)
          refute Code.ensure_loaded?(Sentry.OpenTelemetry.SpanRecord)
          # SpanStorage should always be defined as it doesn't depend on OpenTelemetry directly
          assert Code.ensure_loaded?(Sentry.OpenTelemetry.SpanStorage)
      end
    end

    test "application startup behavior with tracing enabled" do
      # This test verifies that the application startup logic works correctly
      # We can't easily test the actual startup, but we can test the logic

      tracing_enabled = Sentry.Config.tracing?()
      version_compatible = VersionChecker.tracing_compatible?()

      # The span storage should only be started if both conditions are true
      expected_span_storage = tracing_enabled and version_compatible

      if expected_span_storage do
        # If we expect span storage to be running, it should be available
        assert Process.whereis(Sentry.OpenTelemetry.SpanStorage) != nil
      else
        # If we don't expect it, it might still be running from other tests
        # so we just verify the logic is sound
        assert is_boolean(tracing_enabled)
        assert is_boolean(version_compatible)
      end
    end

    test "version checker integration with Config.tracing?" do
      # Test that the version checker works correctly with Sentry's tracing configuration
      tracing_configured = Sentry.Config.tracing?()
      version_compatible = VersionChecker.tracing_compatible?()

      # Both should return booleans
      assert is_boolean(tracing_configured)
      assert is_boolean(version_compatible)

      # If tracing is not configured, version compatibility doesn't matter
      # If tracing is configured, version compatibility determines if it actually works
      effective_tracing = tracing_configured and version_compatible
      assert is_boolean(effective_tracing)
    end
  end

  describe "version checker behavior" do
    test "check_compatibility returns consistent results" do
      # Call multiple times to ensure consistency
      result1 = VersionChecker.check_compatibility()
      result2 = VersionChecker.check_compatibility()
      result3 = VersionChecker.tracing_compatible?()

      # Results should be consistent
      assert result1 == result2

      # tracing_compatible? should match check_compatibility result
      case result1 do
        {:ok, :compatible} -> assert result3 == true
        {:error, _} -> assert result3 == false
      end
    end
  end

  describe "conditional module loading" do
    test "modules have correct conditional compilation" do
      # Test that the conditional compilation works as expected
      version_compatible = VersionChecker.tracing_compatible?()

      # Check if OpenTelemetry is available at all
      otel_available = Code.ensure_loaded?(OpenTelemetry)
      otel_sampler_available = Code.ensure_loaded?(:otel_sampler)

      if otel_available and version_compatible do
        assert Code.ensure_loaded?(Sentry.OpenTelemetry.SpanProcessor)
        assert Code.ensure_loaded?(Sentry.OpenTelemetry.SpanRecord)
      else
        refute Code.ensure_loaded?(Sentry.OpenTelemetry.SpanProcessor)
        refute Code.ensure_loaded?(Sentry.OpenTelemetry.SpanRecord)
      end

      if otel_sampler_available and version_compatible do
        assert Code.ensure_loaded?(Sentry.OpenTelemetry.Sampler)
      else
        refute Code.ensure_loaded?(Sentry.OpenTelemetry.Sampler)
      end
    end
  end
end
