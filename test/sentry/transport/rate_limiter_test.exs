defmodule Sentry.Transport.RateLimiterTest do
  use Sentry.Case, async: true

  import Sentry.TestHelpers
  import ExUnit.CaptureLog

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

    test "a byte category parsed from the header gates its count category" do
      # X-Sentry-Rate-Limits: 60:log_byte:organization
      RateLimiter.update_rate_limits("60:log_byte:organization")

      assert RateLimiter.rate_limited?("log_byte") == true
      assert RateLimiter.rate_limited_for_category?("log_item") == true
    end
  end

  describe "rate_limited_for_category?/1" do
    test "gates log_item on the log_byte limit as well" do
      set_rate_limit("log_byte")

      assert RateLimiter.rate_limited_for_category?("log_item") == true
      assert RateLimiter.rate_limited?("log_item") == false
    end

    test "gates trace_metric on the trace_metric_byte limit as well" do
      set_rate_limit("trace_metric_byte")

      assert RateLimiter.rate_limited_for_category?("trace_metric") == true
      assert RateLimiter.rate_limited?("trace_metric") == false
    end

    test "gates attachments on the attachment limit" do
      set_rate_limit("attachment")

      assert RateLimiter.rate_limited_for_category?("attachment") == true
      assert RateLimiter.rate_limited?("attachment") == true
    end

    test "gates attachments on the attachment_item limit" do
      set_rate_limit("attachment_item")

      assert RateLimiter.rate_limited_for_category?("attachment") == true
      assert RateLimiter.rate_limited?("attachment") == false
    end

    test "does not gate errors on attachment limits" do
      set_rate_limit("attachment")
      set_rate_limit("attachment_item")

      assert RateLimiter.rate_limited_for_category?("error") == false
    end

    test "gates a category on itself when it has no companion byte category" do
      set_rate_limit("error")

      assert RateLimiter.rate_limited_for_category?("error") == true
      assert RateLimiter.rate_limited_for_category?("transaction") == false
    end
  end

  describe "update_rate_limits/1" do
    test "stores category-specific rate limits in ETS" do
      RateLimiter.update_rate_limits("60:error")

      assert [{_, expiry}] = :ets.lookup(table_name(), "error")
      assert_in_delta expiry, System.system_time(:millisecond) + 60_000, 1000
    end

    test "stores a fractional retry delay at millisecond precision" do
      RateLimiter.update_rate_limits("1.5:error")

      assert [{_, expiry}] = :ets.lookup(table_name(), "error")
      assert_in_delta expiry, System.system_time(:millisecond) + 1500, 100
    end

    test "stores global rate limit with :global key" do
      RateLimiter.update_rate_limits("60::")

      assert [{:global, expiry}] = :ets.lookup(table_name(), :global)
      assert_in_delta expiry, System.system_time(:millisecond) + 60_000, 1000
    end

    test "extends an active limit when a longer one arrives" do
      RateLimiter.update_rate_limits("1:error")
      first_expiry = stored_expiry("error")

      RateLimiter.update_rate_limits("15:error")

      assert stored_expiry("error") > first_expiry
    end

    test "keeps the existing expiry when a shorter limit arrives" do
      RateLimiter.update_rate_limits("60:error")
      expiry = stored_expiry("error")

      RateLimiter.update_rate_limits("1:error")

      assert stored_expiry("error") == expiry
    end

    test "applies a new limit over an expired entry that has not been swept yet" do
      set_rate_limit("error", duration: -10)

      RateLimiter.update_rate_limits("60:error")

      assert RateLimiter.rate_limited?("error") == true
    end

    test "keeps the longest delay when a category repeats in one header" do
      RateLimiter.update_rate_limits("1:error, 60:error")
      RateLimiter.update_rate_limits("60:transaction, 1:transaction")

      assert_in_delta stored_expiry("error"), System.system_time(:millisecond) + 60_000, 1000

      assert_in_delta stored_expiry("transaction"),
                      System.system_time(:millisecond) + 60_000,
                      1000
    end
  end

  describe "update_global_rate_limit/1" do
    test "stores global rate limit from Retry-After" do
      RateLimiter.update_global_rate_limit(60)

      assert [{:global, expiry}] = :ets.lookup(table_name(), :global)
      assert_in_delta expiry, System.system_time(:millisecond) + 60_000, 1000
    end

    test "keeps the existing expiry when a shorter global limit arrives" do
      RateLimiter.update_global_rate_limit(60)
      expiry = stored_expiry(:global)

      RateLimiter.update_global_rate_limit(1)

      assert stored_expiry(:global) == expiry
    end

    test "keeps the existing expiry when a shorter limit arrives from the header" do
      RateLimiter.update_rate_limits("60::organization")
      expiry = stored_expiry(:global)

      RateLimiter.update_global_rate_limit(1)

      assert stored_expiry(:global) == expiry
    end
  end

  describe "rate_limited?/1" do
    test "returns true for rate-limited category" do
      set_rate_limit("error")

      assert RateLimiter.rate_limited?("error") == true
    end

    test "returns false for non-rate-limited category" do
      assert RateLimiter.rate_limited?("error") == false
    end

    test "returns false for expired rate limit" do
      set_rate_limit("error", duration: -10)

      assert RateLimiter.rate_limited?("error") == false
    end

    test "returns true when global limit is active" do
      set_rate_limit(:global)

      # Any category should be limited
      assert RateLimiter.rate_limited?("error") == true
      assert RateLimiter.rate_limited?("transaction") == true
    end

    test "returns true if either category or global limit is active" do
      set_rate_limit("error", duration: 30)
      set_rate_limit(:global)

      assert RateLimiter.rate_limited?("error") == true
    end
  end

  describe "logging of new rate limits" do
    test "announces every newly limited category in a single message" do
      log =
        capture_log(fn ->
          RateLimiter.update_rate_limits("60:error;transaction:key, 120:attachment:org")
        end)

      assert length(String.split(log, "Sentry is rate-limiting")) == 2
      assert log =~ ~s("error")
      assert log =~ ~s("transaction")
      assert log =~ ~s("attachment")
      assert log =~ "60s"
      assert log =~ "120s"
    end

    test "stays quiet when a shorter limit arrives for an active category" do
      RateLimiter.update_rate_limits("60:error:key")

      log = capture_log(fn -> RateLimiter.update_rate_limits("30:error:key") end)

      refute log =~ "Sentry is rate-limiting"
    end

    test "announces a new limit landing on an expired entry" do
      set_rate_limit("error", duration: -10)

      log = capture_log(fn -> RateLimiter.update_rate_limits("60:error:key") end)

      assert log =~ "Sentry is rate-limiting"
      assert log =~ ~s("error")
    end

    test "announces a limit once when responses race" do
      rounds = 20

      announcements =
        for round <- 1..rounds, reduce: 0 do
          acc ->
            log = capture_log(fn -> race_update_rate_limits("error-#{round}") end)
            acc + length(String.split(log, "Sentry is rate-limiting")) - 1
        end

      assert announcements == rounds
    end
  end

  defp race_update_rate_limits(category, senders \\ 40) do
    table = table_name()
    release = :atomics.new(1, [])
    parent = self()

    tasks =
      for _ <- 1..senders do
        Task.async(fn ->
          Process.put(:rate_limiter_table_name, table)
          send(parent, :ready)
          await_release(release)
          RateLimiter.update_rate_limits("60:#{category}:key")
        end)
      end

    for _ <- 1..senders, do: assert_receive(:ready)
    :atomics.put(release, 1, 1)
    Task.await_many(tasks, 5000)
  end

  defp await_release(release) do
    if :atomics.get(release, 1) == 1, do: :ok, else: await_release(release)
  end

  defp table_name, do: Process.get(:rate_limiter_table_name)

  defp stored_expiry(category) do
    assert [{^category, expiry}] = :ets.lookup(table_name(), category)
    expiry
  end
end
