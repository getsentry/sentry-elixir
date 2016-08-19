defmodule Sentry.Util do
  @moduledoc """
    Provides basic utility functions.
  """

  @doc """
    Generates a unix timestamp
  """
  @spec unix_timestamp :: Integer.t
  def unix_timestamp do
    :os.system_time(:seconds)
  end

  @doc """
    Generates a iso8601_timestamp
  """
  @spec iso8601_timestamp :: String.t
  def iso8601_timestamp do
    DateTime.utc_now()
    |> DateTime.to_iso8601()
  end
end
