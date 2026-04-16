defmodule Sentry.Test.Scope do
  @moduledoc false

  # Value struct representing one test's per-test config overrides.
  #
  # A Scope owns its `owner_pid` and `:overrides` map. The set of pids
  # explicitly routed onto this scope (via `Sentry.Test.Config.allow/2`
  # or the auto-allow in `put/1`) lives in a separate ETS index owned by
  # `Sentry.Test.Registry` — that's the source of truth for routing
  # decisions and conflict detection, which need atomic semantics that a
  # `MapSet` field on this struct can't provide.
  #
  # All operations are pure — storage and lifecycle live in
  # `Sentry.Test.Scope.Registry`.

  @enforce_keys [:owner_pid]
  defstruct owner_pid: nil,
            overrides: %{}

  @type t :: %__MODULE__{}

  @spec new(pid()) :: t()
  def new(owner_pid) when is_pid(owner_pid) do
    %__MODULE__{owner_pid: owner_pid}
  end

  @spec put_override(t(), atom(), term()) :: t()
  def put_override(%__MODULE__{overrides: overrides} = scope, key, value) when is_atom(key) do
    %{scope | overrides: Map.put(overrides, key, value)}
  end

  @spec fetch_override(t(), atom()) :: {:ok, term()} | :error
  def fetch_override(%__MODULE__{overrides: overrides}, key) when is_atom(key) do
    Map.fetch(overrides, key)
  end
end
