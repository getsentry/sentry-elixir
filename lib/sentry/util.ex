defmodule Sentry.Util do
  @moduledoc """
    Provides basic utility functions.
  """

  @rfc_4122_variant10 2
  @uuid_v4_identifier 4

  @doc """
    Generates a unix timestamp
  """
  @spec unix_timestamp :: pos_integer()
  def unix_timestamp do
    :os.system_time(:seconds)
  end

  @doc """
    Generates a iso8601_timestamp without microseconds and timezone
  """
  @spec iso8601_timestamp :: String.t()
  def iso8601_timestamp do
    DateTime.utc_now()
    |> Map.put(:microsecond, {0, 0})
    |> DateTime.to_iso8601()
    |> String.trim_trailing("Z")
  end

  @spec mix_deps_to_map([Mix.Dep.t()]) :: map()
  def mix_deps_to_map([%Mix.Dep{} | _rest] = modules) do
    Enum.reduce(modules, %{}, fn x, acc ->
      case x.status do
        {:ok, version} -> Map.put(acc, x.app, version)
        _ -> acc
      end
    end)
  end

  def mix_deps_to_map(modules), do: modules

  @doc """
  Per http://www.ietf.org/rfc/rfc4122.txt
  """
  @spec uuid4_hex() :: String.t()
  def uuid4_hex() do
    <<time_low_mid::48, _version::4, time_high::12, _reserved::2, rest::62>> =
      :crypto.strong_rand_bytes(16)

    <<time_low_mid::48, @uuid_v4_identifier::4, time_high::12, @rfc_4122_variant10::2, rest::62>>
    |> Base.encode16(case: :lower)
  end
end
