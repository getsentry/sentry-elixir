defmodule Sentry.Dev.VersionPolicy do
  @moduledoc """
  Classifies version bumps and decides which are allowed for `mix sentry.bump_lockfiles`.

  The default policy keeps patch and minor bumps and rejects anything that crosses a
  major boundary. Following semver, `0.x` releases treat the *minor* segment as the
  breaking axis, so a `0.20 -> 0.21` bump is considered breaking by default.

  This module is dev/CI tooling and is not part of the public API.
  """

  @moduledoc since: "13.3.0"

  @type opts :: %{
          allow_major: boolean(),
          allow_major_for: MapSet.t(String.t()),
          strict_0x: boolean()
        }

  @type kind :: :patch | :minor | :major | :"0x_minor_breaking" | :downgrade | :unparseable

  @doc """
  Builds a normalized options map from the keyword options parsed off the CLI.
  """
  @spec opts(keyword()) :: opts()
  def opts(parsed) do
    %{
      allow_major: Keyword.get(parsed, :allow_major, false),
      allow_major_for: parsed |> Keyword.get(:allow_major_for, []) |> MapSet.new(),
      strict_0x: Keyword.get(parsed, :strict_0x, true)
    }
  end

  @doc """
  Classifies a bump from `from` to `to`.

  Returns `:unparseable` if either version cannot be parsed, `:downgrade` if `to` is
  not greater than `from`, and otherwise `:patch`, `:minor`, `:major`, or
  `:"0x_minor_breaking"` (a breaking minor bump within the `0.x` series).
  """
  @spec classify(String.t() | nil, String.t(), opts()) :: kind()
  def classify(from, to, opts) do
    with {:ok, from_v} <- parse(from),
         {:ok, to_v} <- parse(to) do
      cond do
        Version.compare(to_v, from_v) != :gt ->
          :downgrade

        from_v.major == 0 and to_v.major == 0 and from_v.minor != to_v.minor and opts.strict_0x ->
          :"0x_minor_breaking"

        from_v.major != to_v.major ->
          :major

        from_v.minor != to_v.minor ->
          :minor

        true ->
          :patch
      end
    else
      _ -> :unparseable
    end
  end

  @doc """
  Returns `true` when a bump from `from` to `to` crosses a breaking boundary under the
  current policy. A new dependency (`from == nil`) is never breaking.
  """
  @spec breaking?(String.t() | nil, String.t(), opts()) :: boolean()
  def breaking?(nil, _to, _opts), do: false

  def breaking?(from, to, opts) do
    classify(from, to, opts) in [:major, :"0x_minor_breaking"]
  end

  @doc """
  Returns `true` when bumping `dep` from `from` to `to` is allowed.

  Non-breaking bumps are always allowed. Breaking bumps are allowed only when
  `:allow_major` is set globally or `dep` appears in `:allow_major_for`.
  """
  @spec allowed?(String.t(), String.t() | nil, String.t(), opts()) :: boolean()
  def allowed?(dep, from, to, opts) do
    cond do
      not breaking?(from, to, opts) -> true
      opts.allow_major -> true
      MapSet.member?(opts.allow_major_for, dep) -> true
      true -> false
    end
  end

  defp parse(nil), do: :error
  defp parse(version) when is_binary(version), do: Version.parse(version)
end
