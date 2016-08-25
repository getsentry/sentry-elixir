defmodule Sentry.Fuse do
  @api_fuse_name :sentry_api
  @max_failures 5
  @failure_period 5_000
  @reset_period 30_000

  def install_fuse do
    :fuse.install(:sentry_api, {{:standard, @max_failures, @failure_period}, {:reset, @reset_period}})
  end

  def api_fuse_name do
    @api_fuse_name
  end
end
