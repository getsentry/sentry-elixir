defmodule Sentry.Util do
  @spec unix_timestamp :: Integer.t
  def unix_timestamp do
    :os.system_time(:seconds)
  end

  @spec iso8601_timestamp :: String.t
  def iso8601_timestamp do
    DateTime.utc_now()
    |> DateTime.to_iso8601()
  end
end
