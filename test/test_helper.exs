ExUnit.start(assert_receive_timeout: 1000)

# Start the default-named RateLimiter globally for the entire test suite.
# This is needed because sender pool workers (which are global) access the rate
# limiter using the default name. Individual tests use isolated rate limiters
# (started by Sentry.Case) for test process operations, but async operations
# via sender workers need the default-named rate limiter.
{:ok, _} = Sentry.Transport.RateLimiter.start_link([])

File.rm_rf!(Sentry.Sources.path_of_packaged_source_code())

ExUnit.after_suite(fn _ ->
  File.rm_rf!(Sentry.Sources.path_of_packaged_source_code())
end)
