defmodule Sentry.Dev do
  @moduledoc """
  Shared helpers for the `mix sentry.bump_lockfiles` dev tooling (the `Sentry.Dev.*`
  modules).

  This module is dev/CI tooling and is not part of the public API.
  """

  @moduledoc since: "13.3.0"

  @doc """
  Splits a comma-separated CLI option string into a trimmed list of values.

  `nil` (an unset option) becomes `[]`.
  """
  @spec csv(String.t() | nil) :: [String.t()]
  def csv(nil), do: []

  def csv(str) when is_binary(str),
    do: str |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
end
