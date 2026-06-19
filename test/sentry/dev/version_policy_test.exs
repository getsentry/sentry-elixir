defmodule Sentry.Dev.VersionPolicyTest do
  use ExUnit.Case, async: true

  alias Sentry.Dev.VersionPolicy

  defp opts(overrides \\ []) do
    VersionPolicy.opts(
      Keyword.merge(
        [allow_major: false, allow_major_for: [], strict_0x: true],
        overrides
      )
    )
  end

  describe "classify/3" do
    test "classifies patch, minor, and major bumps for >= 1.0 versions" do
      assert VersionPolicy.classify("1.2.3", "1.2.4", opts()) == :patch
      assert VersionPolicy.classify("1.2.3", "1.3.0", opts()) == :minor
      assert VersionPolicy.classify("1.2.3", "2.0.0", opts()) == :major
    end

    test "treats 0.x minor bumps as breaking by default" do
      assert VersionPolicy.classify("0.20.0", "0.21.0", opts()) == :"0x_minor_breaking"
      assert VersionPolicy.classify("0.20.0", "0.20.1", opts()) == :patch
    end

    test "treats 0.x minor bumps as a normal minor when strict_0x is disabled" do
      assert VersionPolicy.classify("0.20.0", "0.21.0", opts(strict_0x: false)) == :minor
    end

    test "detects downgrades and equal versions" do
      assert VersionPolicy.classify("1.3.0", "1.2.0", opts()) == :downgrade
      assert VersionPolicy.classify("1.2.0", "1.2.0", opts()) == :downgrade
    end

    test "returns :unparseable for non-semver versions" do
      assert VersionPolicy.classify("not-a-version", "1.0.0", opts()) == :unparseable
      assert VersionPolicy.classify(nil, "1.0.0", opts()) == :unparseable
    end
  end

  describe "breaking?/3" do
    test "minor and patch bumps are not breaking" do
      refute VersionPolicy.breaking?("1.2.3", "1.3.0", opts())
      refute VersionPolicy.breaking?("1.2.3", "1.2.4", opts())
    end

    test "major and 0.x minor bumps are breaking" do
      assert VersionPolicy.breaking?("1.0.0", "2.0.0", opts())
      assert VersionPolicy.breaking?("0.20.0", "0.21.0", opts())
    end

    test "a new dependency (from nil) is never breaking" do
      refute VersionPolicy.breaking?(nil, "2.0.0", opts())
    end
  end

  describe "allowed?/4" do
    test "non-breaking bumps are always allowed" do
      assert VersionPolicy.allowed?("plug", "1.2.3", "1.3.0", opts())
    end

    test "breaking bumps are rejected by default" do
      refute VersionPolicy.allowed?("floki", "0.36.0", "0.37.0", opts())
    end

    test "allow_major permits any breaking bump" do
      assert VersionPolicy.allowed?("floki", "0.36.0", "0.37.0", opts(allow_major: true))
    end

    test "allow_major_for permits only the listed deps" do
      o = opts(allow_major_for: ["opentelemetry"])
      assert VersionPolicy.allowed?("opentelemetry", "1.0.0", "2.0.0", o)
      refute VersionPolicy.allowed?("floki", "0.36.0", "0.37.0", o)
    end
  end
end
