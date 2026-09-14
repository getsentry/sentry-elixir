defmodule Sentry.ConfigTracesSamplerTest do
  use ExUnit.Case, async: true

  import Sentry.TestHelpers

  describe "traces_sampler configuration validation" do
    defmodule TestSampler do
      def sample(_context), do: 0.5
    end

    test "accepts nil" do
      assert :ok = put_test_config(traces_sampler: nil)
      assert Sentry.Config.traces_sampler() == nil
    end

    test "accepts function with arity 1" do
      fun = fn _context -> 0.5 end
      assert :ok = put_test_config(traces_sampler: fun)
      assert Sentry.Config.traces_sampler() == fun
    end

    test "accepts MFA tuple with exported function" do
      assert :ok = put_test_config(traces_sampler: {TestSampler, :sample})
      assert Sentry.Config.traces_sampler() == {TestSampler, :sample}
    end

    test "rejects MFA tuple with non-exported function" do
      assert_raise ArgumentError, ~r/function.*is not exported/, fn ->
        put_test_config(traces_sampler: {TestSampler, :non_existent})
      end
    end

    test "rejects function with wrong arity" do
      fun = fn -> 0.5 end

      assert_raise ArgumentError, ~r/expected :traces_sampler to be/, fn ->
        put_test_config(traces_sampler: fun)
      end
    end

    test "rejects invalid types" do
      assert_raise ArgumentError, ~r/expected :traces_sampler to be/, fn ->
        put_test_config(traces_sampler: "invalid")
      end

      assert_raise ArgumentError, ~r/expected :traces_sampler to be/, fn ->
        put_test_config(traces_sampler: 123)
      end

      assert_raise ArgumentError, ~r/expected :traces_sampler to be/, fn ->
        put_test_config(traces_sampler: [])
      end
    end
  end

  describe "tracing? function" do
    test "returns true when traces_sample_rate is set" do
      put_test_config(traces_sample_rate: 0.5, traces_sampler: nil)

      assert Sentry.Config.tracing?()
    end

    test "returns true when traces_sampler is set" do
      put_test_config(traces_sample_rate: nil, traces_sampler: fn _ -> 0.5 end)

      assert Sentry.Config.tracing?()
    end

    test "returns true when both are set" do
      put_test_config(traces_sample_rate: 0.5, traces_sampler: fn _ -> 0.5 end)

      assert Sentry.Config.tracing?()
    end

    test "returns false when neither is set" do
      put_test_config(traces_sample_rate: nil, traces_sampler: nil)

      refute Sentry.Config.tracing?()
    end
  end
end
