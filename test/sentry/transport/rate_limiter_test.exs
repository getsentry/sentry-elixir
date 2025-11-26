defmodule Sentry.Transport.RateLimiterTest do
  use ExUnit.Case, async: true

  alias Sentry.Transport.RateLimiter

  setup do
    # Start a fresh RateLimiter with unique names per test
    uid = System.unique_integer([:positive])
    server_name = :"test_rate_limiter_#{uid}"
    table_name = :"test_rate_limiter_table_#{uid}"

    start_supervised!({RateLimiter, name: server_name, table_name: table_name})

    {:ok, table_name: table_name}
  end

  describe "parse_rate_limits_header/1" do
    test "parses single category limit", %{table_name: table_name} do
      # X-Sentry-Rate-Limits: 60:error
      RateLimiter.update_rate_limits("60:error", table_name: table_name)

      assert RateLimiter.rate_limited?("error", table_name: table_name) == true
      assert RateLimiter.rate_limited?("transaction", table_name: table_name) == false
    end

    test "parses multiple categories with same limit", %{table_name: table_name} do
      # X-Sentry-Rate-Limits: 60:error;transaction
      RateLimiter.update_rate_limits("60:error;transaction", table_name: table_name)

      assert RateLimiter.rate_limited?("error", table_name: table_name) == true
      assert RateLimiter.rate_limited?("transaction", table_name: table_name) == true
    end

    test "parses multiple limits separated by comma", %{table_name: table_name} do
      # X-Sentry-Rate-Limits: 60:transaction, 2700:default;error
      RateLimiter.update_rate_limits("60:transaction, 2700:default;error", table_name: table_name)

      assert RateLimiter.rate_limited?("transaction", table_name: table_name) == true
      assert RateLimiter.rate_limited?("default", table_name: table_name) == true
      assert RateLimiter.rate_limited?("error", table_name: table_name) == true
    end

    test "parses empty categories as global limit", %{table_name: table_name} do
      # X-Sentry-Rate-Limits: 60::organization
      RateLimiter.update_rate_limits("60::organization", table_name: table_name)

      # Global limit affects all categories
      assert RateLimiter.rate_limited?("error", table_name: table_name) == true
      assert RateLimiter.rate_limited?("transaction", table_name: table_name) == true
    end

    test "ignores unknown dimensions", %{table_name: table_name} do
      # X-Sentry-Rate-Limits: 60:error:organization:quota_exceeded
      RateLimiter.update_rate_limits("60:error:organization:quota_exceeded",
        table_name: table_name
      )

      assert RateLimiter.rate_limited?("error", table_name: table_name) == true
    end

    test "handles malformed entries gracefully", %{table_name: table_name} do
      # X-Sentry-Rate-Limits: invalid, 60:error, bad_format
      RateLimiter.update_rate_limits("invalid, 60:error, bad_format", table_name: table_name)

      # Only the valid entry should be parsed
      assert RateLimiter.rate_limited?("error", table_name: table_name) == true
    end

    test "handles spaces after commas", %{table_name: table_name} do
      # X-Sentry-Rate-Limits: 60:error, 120:transaction
      RateLimiter.update_rate_limits("60:error, 120:transaction", table_name: table_name)

      assert RateLimiter.rate_limited?("error", table_name: table_name) == true
      assert RateLimiter.rate_limited?("transaction", table_name: table_name) == true
    end
  end

  describe "update_rate_limits/1" do
    test "stores category-specific rate limits in ETS", %{table_name: table_name} do
      RateLimiter.update_rate_limits("60:error", table_name: table_name)

      assert [{_, expiry}] = :ets.lookup(table_name, "error")
      assert expiry > System.system_time(:second)
    end

    test "stores global rate limit with :global key", %{table_name: table_name} do
      RateLimiter.update_rate_limits("60::", table_name: table_name)

      assert [{:global, expiry}] = :ets.lookup(table_name, :global)
      assert expiry > System.system_time(:second)
    end

    test "overwrites existing rate limits", %{table_name: table_name} do
      RateLimiter.update_rate_limits("1:error", table_name: table_name)
      first_expiry = :ets.lookup(table_name, "error") |> hd() |> elem(1)

      RateLimiter.update_rate_limits("15:error", table_name: table_name)
      second_expiry = :ets.lookup(table_name, "error") |> hd() |> elem(1)

      assert second_expiry > first_expiry
    end
  end

  describe "update_global_rate_limit/1" do
    test "stores global rate limit from Retry-After", %{table_name: table_name} do
      RateLimiter.update_global_rate_limit(60, table_name: table_name)

      assert [{:global, expiry}] = :ets.lookup(table_name, :global)
      assert_in_delta expiry, System.system_time(:second) + 60, 1
    end
  end

  describe "rate_limited?/1" do
    test "returns true for rate-limited category", %{table_name: table_name} do
      now = System.system_time(:second)
      :ets.insert(table_name, {"error", now + 60})

      assert RateLimiter.rate_limited?("error", table_name: table_name) == true
    end

    test "returns false for non-rate-limited category", %{table_name: table_name} do
      assert RateLimiter.rate_limited?("error", table_name: table_name) == false
    end

    test "returns false for expired rate limit", %{table_name: table_name} do
      now = System.system_time(:second)
      :ets.insert(table_name, {"error", now - 10})

      assert RateLimiter.rate_limited?("error", table_name: table_name) == false
    end

    test "returns true when global limit is active", %{table_name: table_name} do
      now = System.system_time(:second)
      :ets.insert(table_name, {:global, now + 60})

      # Any category should be limited
      assert RateLimiter.rate_limited?("error", table_name: table_name) == true
      assert RateLimiter.rate_limited?("transaction", table_name: table_name) == true
    end

    test "returns true if either category or global limit is active", %{table_name: table_name} do
      now = System.system_time(:second)
      :ets.insert(table_name, {"error", now + 30})
      :ets.insert(table_name, {:global, now + 60})

      assert RateLimiter.rate_limited?("error", table_name: table_name) == true
    end
  end
end
