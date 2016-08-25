defmodule Sentry.Fuse do
  @api_fuse_name :sentry_api
  @max_failures 5
  @failure_period 5_000
  @reset_period 30_000

  @moduledoc """
  To avoid sending requests to the Sentry API during periods of failure, we use
  a circuit breaker to update and check the health of the API. Currently, the
  fuse is configured to melt if the API returns unsuccessful responses 5 times
  within 5 seconds.  Following a melt, the fuse will be reset and API attempts
  will be allowed again after a 30 second reset period.
  """

  def install_fuse do
    :fuse.install(:sentry_api, {{:standard, @max_failures, @failure_period}, {:reset, @reset_period}})
  end

  def api_fuse_name do
    @api_fuse_name
  end
end
