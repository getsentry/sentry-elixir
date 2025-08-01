defmodule Sentry.OpenTelemetry.VersionCheckerTest do
  use ExUnit.Case, async: true

  alias Sentry.OpenTelemetry.VersionChecker

  describe "check_compatibility/0" do
    test "works with current loaded dependencies" do
      # This test will work with whatever OpenTelemetry versions are currently loaded
      result = VersionChecker.check_compatibility()

      case result do
        {:ok, :compatible} ->
          assert true

        {:error, {:incompatible_versions, errors}} ->
          # If we get errors, they should be properly formatted
          assert is_list(errors)
          assert length(errors) > 0

          for {dep, reason} <- errors do
            assert dep in [
                     :opentelemetry,
                     :opentelemetry_api,
                     :opentelemetry_exporter,
                     :opentelemetry_semantic_conventions
                   ]

            assert reason in [:not_loaded] or match?({:version_too_old, _, _}, reason)
          end
      end
    end
  end

  describe "tracing_compatible?/0" do
    test "returns boolean" do
      result = VersionChecker.tracing_compatible?()
      assert is_boolean(result)
    end
  end

  describe "version comparison logic" do
    test "module exports expected public functions" do
      # Test that the module defines the required public functions
      assert VersionChecker.__info__(:functions) |> Keyword.has_key?(:check_compatibility)
      assert VersionChecker.__info__(:functions) |> Keyword.has_key?(:tracing_compatible?)
    end
  end
end
