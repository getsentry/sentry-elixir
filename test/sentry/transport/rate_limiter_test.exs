defmodule Sentry.Transport.RateLimiterTest do
  use Sentry.Case, async: true

  alias Sentry.Transport.RateLimiter

  describe "parse_rate_limits_header/1" do
    test "parses single category limit" do
      # X-Sentry-Rate-Limits: 60:error
      RateLimiter.update_rate_limits("60:error")

      assert RateLimiter.rate_limited?("error") == true
      assert RateLimiter.rate_limited?("transaction") == false
    end

    test "parses multiple categories with same limit" do
      # X-Sentry-Rate-Limits: 60:error;transaction
      RateLimiter.update_rate_limits("60:error;transaction")

      assert RateLimiter.rate_limited?("error") == true
      assert RateLimiter.rate_limited?("transaction") == true
    end

    test "parses multiple limits separated by comma" do
      # X-Sentry-Rate-Limits: 60:transaction, 2700:default;error
      RateLimiter.update_rate_limits("60:transaction, 2700:default;error")

      assert RateLimiter.rate_limited?("transaction") == true
      assert RateLimiter.rate_limited?("default") == true
      assert RateLimiter.rate_limited?("error") == true
    end

    test "parses empty categories as global limit" do
      # X-Sentry-Rate-Limits: 60::organization
      RateLimiter.update_rate_limits("60::organization")

      # Global limit affects all categories
      assert RateLimiter.rate_limited?("error") == true
      assert RateLimiter.rate_limited?("transaction") == true
    end

    test "ignores unknown dimensions" do
      # X-Sentry-Rate-Limits: 60:error:organization:quota_exceeded
      RateLimiter.update_rate_limits("60:error:organization:quota_exceeded")

      assert RateLimiter.rate_limited?("error") == true
    end

    test "handles malformed entries gracefully" do
      # X-Sentry-Rate-Limits: invalid, 60:error, bad_format
      RateLimiter.update_rate_limits("invalid, 60:error, bad_format")

      # Only the valid entry should be parsed
      assert RateLimiter.rate_limited?("error") == true
    end

    test "handles spaces after commas" do
      # X-Sentry-Rate-Limits: 60:error, 120:transaction
      RateLimiter.update_rate_limits("60:error, 120:transaction")

      assert RateLimiter.rate_limited?("error") == true
      assert RateLimiter.rate_limited?("transaction") == true
    end
  end

  describe "update_rate_limits/1" do
    test "stores category-specific rate limits in ETS" do
      RateLimiter.update_rate_limits("60:error")

      assert [{_, expiry}] = :ets.lookup(table_name(), "error")
      assert expiry > System.system_time(:second)
    end

    test "stores global rate limit with :global key" do
      RateLimiter.update_rate_limits("60::")

      assert [{:global, expiry}] = :ets.lookup(table_name(), :global)
      assert expiry > System.system_time(:second)
    end

    test "overwrites existing rate limits" do
      RateLimiter.update_rate_limits("1:error")
      first_expiry = :ets.lookup(table_name(), "error") |> hd() |> elem(1)

      RateLimiter.update_rate_limits("15:error")
      second_expiry = :ets.lookup(table_name(), "error") |> hd() |> elem(1)

      assert second_expiry > first_expiry
    end
  end

  describe "update_global_rate_limit/1" do
    test "stores global rate limit from Retry-After" do
      RateLimiter.update_global_rate_limit(60)

      assert [{:global, expiry}] = :ets.lookup(table_name(), :global)
      assert_in_delta expiry, System.system_time(:second) + 60, 1
    end
  end

  describe "rate_limited?/1" do
    test "returns true for rate-limited category" do
      now = System.system_time(:second)
      :ets.insert(table_name(), {"error", now + 60})

      assert RateLimiter.rate_limited?("error") == true
    end

    test "returns false for non-rate-limited category" do
      assert RateLimiter.rate_limited?("error") == false
    end

    test "returns false for expired rate limit" do
      now = System.system_time(:second)
      :ets.insert(table_name(), {"error", now - 10})

      assert RateLimiter.rate_limited?("error") == false
    end

    test "returns true when global limit is active" do
      now = System.system_time(:second)
      :ets.insert(table_name(), {:global, now + 60})

      # Any category should be limited
      assert RateLimiter.rate_limited?("error") == true
      assert RateLimiter.rate_limited?("transaction") == true
    end

    test "returns true if either category or global limit is active" do
      now = System.system_time(:second)
      :ets.insert(table_name(), {"error", now + 30})
      :ets.insert(table_name(), {:global, now + 60})

      assert RateLimiter.rate_limited?("error") == true
    end
  end

  defp table_name, do: Process.get(:rate_limiter_table_name)
end
