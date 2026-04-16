defmodule Sentry.Test.Scope.Registry do
  @moduledoc false

  # Lifecycle and resolution for `Sentry.Test.Scope`.
  #
  # Storage:
  #
  #   * `{:sentry_test_scope, owner_pid} -> %Scope{}` in `:persistent_term` —
  #     one entry per active test scope, owns its overrides.
  #   * `:sentry_test_scope_allows` ETS table (named, public, set) —
  #     reverse index `{allowed_pid, owner_pid}` mapping each
  #     explicitly-routed pid back to the scope that claimed it.
  #     Owned by `Sentry.Test.Registry`. Direct ETS reads on the config
  #     read path; conflict-checked writes serialize through that
  #     GenServer for atomic check-and-insert.
  #   * `@counter_key -> :counters.t()` — atomic counter for cheap
  #     "any active scopes?" short-circuits, so config reads in
  #     production cost essentially nothing.
  #
  # Resolution (`resolve/1`) tries three strategies in order, each O(1)
  # per candidate pid (no iteration over active scopes):
  #
  #   1. by_callers   — walk `[pid | $callers]`; try `fetch/1` on each
  #                     (the candidate is itself a scope owner) and the
  #                     reverse-allow lookup (the candidate is allowed
  #                     by some scope).
  #   2. by_ancestor  — walk ancestors transitively; try `fetch/1` on
  #                     each (an ancestor is a scope owner — covers
  #                     GenServers started via `start_supervised/1`).
  #   3. by_allow     — walk `[pid | ancestors]`; reverse-allow lookup
  #                     for each candidate (the pid was explicitly
  #                     routed onto a scope via `allow/2` or
  #                     auto-allowed in `Config.put/1`).
  #
  # Globally-supervised processes (`:logger`, `:logger_sup`,
  # `Sentry.Supervisor`) have no caller/ancestor link to any test and
  # rely on strategy 3. `Sentry.Test.Config.put/1` soft-allows them onto
  # the calling scope so routing is explicit and bounded to the owning
  # test. An implicit "single active scope" fallback would otherwise
  # route every stray log event (e.g. OTP's asynchronous
  # callback-crashed meta-event emitted after a handler callback raises)
  # to whichever test happens to be active when the event arrives — a
  # cross-test leak we cannot tolerate.

  alias Sentry.Test.Registry, as: TestRegistry
  alias Sentry.Test.Scope

  require Logger

  @counter_key :sentry_test_scope_counter
  @scope_key :sentry_test_scope
  @ancestor_walk_depth 8

  # `Process.info(pid, :parent)` was added in OTP 25. On older releases the
  # call raises `ArgumentError` for an unrecognized info item, so we gate the
  # parent-pid walk at compile time instead. On OTP < 25 the ancestor walk
  # falls back to `$ancestors` only — losing parent-link resolution for
  # processes started via `spawn/spawn_monitor`, but the SDK still works.
  @otp_release :erlang.system_info(:otp_release) |> List.to_integer()
  @supports_parent_info @otp_release >= 25

  @type resolution :: {:ok, Scope.t()} | :none

  @spec maybe_init() :: :ok
  def maybe_init do
    case :persistent_term.get(@counter_key, nil) do
      nil -> :persistent_term.put(@counter_key, :counters.new(1, [:atomics]))
      _ref -> :ok
    end

    :ok
  end

  @spec fetch(pid()) :: {:ok, Scope.t()} | :error
  def fetch(owner_pid) when is_pid(owner_pid) do
    case :persistent_term.get({@scope_key, owner_pid}, :__not_set__) do
      :__not_set__ -> :error
      %Scope{} = scope -> {:ok, scope}
    end
  end

  @doc """
  Atomically updates the scope owned by `owner_pid`, creating a new
  scope on first call and registering cleanup via
  `ExUnit.Callbacks.on_exit/1`.

  Not concurrency-safe across processes — each test only mutates its
  own scope from its own process, so in practice there is no
  contention.
  """
  @spec update(pid(), (Scope.t() -> Scope.t())) :: Scope.t()
  def update(owner_pid, fun) when is_pid(owner_pid) and is_function(fun, 1) do
    scope =
      case fetch(owner_pid) do
        {:ok, existing} ->
          existing

        :error ->
          new_scope = Scope.new(owner_pid)
          bump_counter()
          register_cleanup(owner_pid)
          new_scope
      end

    updated = fun.(scope)
    :persistent_term.put({@scope_key, owner_pid}, updated)
    updated
  end

  @doc """
  Returns the live owner_pid that has explicitly allowed `allowed_pid`,
  or `nil` when no live scope owns it. Direct ETS read; safe to call
  on the hot config-read path.
  """
  @spec lookup_allow_owner(pid()) :: pid() | nil
  def lookup_allow_owner(allowed_pid) when is_pid(allowed_pid) do
    TestRegistry.lookup_allow_owner(allowed_pid)
  end

  @doc """
  Strict claim: routes `allowed_pid` onto `owner_pid`'s scope. Raises
  `Sentry.Test.Scope.AllowConflictError` when a live peer scope already
  owns the pid. Idempotent for the same owner. The check-and-insert is
  atomic — see `Sentry.Test.Registry.claim_allow/3`.
  """
  @spec strict_allow!(pid(), pid()) :: :ok
  def strict_allow!(owner_pid, allowed_pid) when is_pid(owner_pid) and is_pid(allowed_pid) do
    case TestRegistry.claim_allow(owner_pid, allowed_pid, :strict) do
      :ok ->
        :ok

      {:error, {:taken, existing_owner}} ->
        raise Sentry.Test.Scope.AllowConflictError,
          allowed_pid: allowed_pid,
          existing_owner: existing_owner,
          new_owner: owner_pid
    end
  end

  @doc """
  Soft claim: routes `allowed_pid` onto `owner_pid`'s scope when free.
  Silent no-op when a live peer scope already owns the pid (the first
  active scope to claim a global wins; concurrent scopes fall through
  to the default config rather than to another test's scope). `nil`
  pids — e.g. from `Process.whereis/1` for an unregistered name — are
  ignored. The check-and-insert is atomic — see
  `Sentry.Test.Registry.claim_allow/3`.
  """
  @spec soft_allow(pid(), pid() | nil) :: :ok
  def soft_allow(_owner_pid, nil), do: :ok

  def soft_allow(owner_pid, allowed_pid) when is_pid(owner_pid) and is_pid(allowed_pid) do
    case TestRegistry.claim_allow(owner_pid, allowed_pid, :soft) do
      :ok -> :ok
      :skipped -> :ok
    end
  end

  @spec unregister(pid()) :: :ok
  def unregister(owner_pid) when is_pid(owner_pid) do
    case :persistent_term.get({@scope_key, owner_pid}, :__not_set__) do
      :__not_set__ ->
        :ok

      %Scope{} ->
        TestRegistry.drop_allows_for(owner_pid)
        :persistent_term.erase({@scope_key, owner_pid})
        decrement_counter()
        :ok
    end
  end

  @spec active_count() :: non_neg_integer()
  def active_count do
    case :persistent_term.get(@counter_key, nil) do
      nil -> 0
      ref -> :counters.get(ref, 1)
    end
  end

  @doc """
  Returns the override for `key` from the first scope on `[self() | $callers]`
  that has it set, or `:default` if no direct caller has overridden it.

  Bypasses the full `resolve/1` chain (no allow / ancestor walk) so
  callers — see `Sentry.Test.setup_collector/1` — can read this test's
  "original" config value without picking up a concurrent test's
  wrapping callback.
  """
  @spec lookup_caller_override(atom()) :: {:ok, term()} | :default
  def lookup_caller_override(key) when is_atom(key) do
    pids = [self() | Process.get(:"$callers", [])]

    Enum.find_value(pids, :default, fn pid ->
      with {:ok, scope} <- fetch(pid),
           {:ok, _value} = found <- Scope.fetch_override(scope, key) do
        found
      else
        _ -> nil
      end
    end)
  end

  @doc """
  Returns the list of currently-active scope structs. Scans
  `:persistent_term.get/0` (an O(N) operation across the whole BEAM
  term table) — reserve for non-hot-path uses (debugging, tests of the
  registry itself). Resolution uses the reverse-index lookups above.
  """
  @spec list_active() :: [Scope.t()]
  def list_active do
    for {{@scope_key, pid}, %Scope{} = scope} <- :persistent_term.get(),
        Process.alive?(pid),
        do: scope
  end

  @spec resolve(pid()) :: resolution()
  def resolve(pid) when is_pid(pid) do
    if active_count() == 0 do
      :none
    else
      with :none <- resolve_by_callers(pid),
           :none <- resolve_by_ancestor(pid),
           :none <- resolve_by_allow(pid) do
        :none
      end
    end
  end

  ## Private helpers

  defp resolve_by_callers(pid) do
    candidates = [pid | Process.get(:"$callers", [])]
    resolve_via_owner_or_allow(candidates)
  end

  defp resolve_by_ancestor(pid) do
    ancestors = collect_ancestors(pid, @ancestor_walk_depth, MapSet.new([pid]))
    resolve_via_owner(ancestors)
  end

  defp resolve_by_allow(pid) do
    candidates = [pid | collect_ancestors(pid, @ancestor_walk_depth, MapSet.new([pid]))]
    resolve_via_allow(candidates)
  end

  # Two scope-cleanup races can return `:error` here: a scope can be
  # unregistered between when we look it up and when we'd act on it
  # (`fetch(candidate)` and `fetch(owner)`). In both cases recurse to
  # the next candidate so the caller never sees `:error` — only
  # `{:ok, scope}` or `:none`. Letting `:error` escape would
  # short-circuit the `with` chain in `resolve/1` with a non-`:none`
  # value and crash the `case` in `Sentry.Test.Config.namespace/1`.
  defp resolve_via_owner_or_allow([]), do: :none

  defp resolve_via_owner_or_allow([candidate | rest]) do
    case fetch(candidate) do
      {:ok, _scope} = found ->
        found

      :error ->
        case lookup_allow_owner(candidate) do
          nil ->
            resolve_via_owner_or_allow(rest)

          owner ->
            case fetch(owner) do
              {:ok, _scope} = found -> found
              :error -> resolve_via_owner_or_allow(rest)
            end
        end
    end
  end

  defp resolve_via_owner([]), do: :none

  defp resolve_via_owner([candidate | rest]) do
    case fetch(candidate) do
      {:ok, _scope} = found -> found
      :error -> resolve_via_owner(rest)
    end
  end

  defp resolve_via_allow([]), do: :none

  defp resolve_via_allow([candidate | rest]) do
    case lookup_allow_owner(candidate) do
      nil ->
        resolve_via_allow(rest)

      owner ->
        case fetch(owner) do
          {:ok, _scope} = found -> found
          :error -> resolve_via_allow(rest)
        end
    end
  end

  defp bump_counter do
    case :persistent_term.get(@counter_key, nil) do
      nil -> :ok
      ref -> :counters.add(ref, 1, 1)
    end
  end

  defp decrement_counter do
    case :persistent_term.get(@counter_key, nil) do
      nil -> :ok
      ref -> :counters.sub(ref, 1, 1)
    end
  end

  defp register_cleanup(owner_pid) do
    ExUnit.Callbacks.on_exit(fn -> unregister(owner_pid) end)
  rescue
    # `on_exit/1` raises outside an ExUnit test process; in that case the
    # caller is responsible for cleanup (or the scope simply lives until the
    # owner process dies and `list_active/0` filters it out via `Process.alive?`).
    _ -> :ok
  end

  defp collect_ancestors(_pid, 0, _seen), do: []

  defp collect_ancestors(pid, depth, seen) do
    direct = pid |> ancestors_of() |> Enum.reject(&MapSet.member?(seen, &1))
    seen = Enum.reduce(direct, seen, &MapSet.put(&2, &1))

    {collected_reversed, _final_seen} =
      Enum.reduce(direct, {[], seen}, fn ancestor, {acc, seen_acc} ->
        sub = collect_ancestors(ancestor, depth - 1, seen_acc)
        seen_acc = Enum.reduce(sub, seen_acc, &MapSet.put(&2, &1))
        {Enum.reverse(sub) ++ acc, seen_acc}
      end)

    direct ++ Enum.reverse(collected_reversed)
  end

  defp ancestors_of(pid) when is_pid(pid) do
    dict_ancestors =
      case Process.info(pid, :dictionary) do
        {:dictionary, dict} ->
          dict
          |> Keyword.get(:"$ancestors", [])
          |> Enum.map(fn
            name when is_atom(name) -> Process.whereis(name)
            p when is_pid(p) -> p
            _ -> nil
          end)

        nil ->
          []
      end

    (dict_ancestors ++ parent_of(pid))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp ancestors_of(_), do: []

  if @supports_parent_info do
    defp parent_of(pid) do
      case Process.info(pid, :parent) do
        {:parent, parent_pid} when is_pid(parent_pid) -> [parent_pid]
        {:parent, _} -> []
        nil -> []
      end
    end
  else
    defp parent_of(_pid), do: []
  end
end

defmodule Sentry.Test.Scope.AllowConflictError do
  @moduledoc false

  defexception [:allowed_pid, :existing_owner, :new_owner]

  @impl true
  def message(%{allowed_pid: allowed, existing_owner: existing, new_owner: new_owner}) do
    "cannot allow #{inspect(allowed)} under #{inspect(new_owner)}: " <>
      "it is already allowed by #{inspect(existing)}"
  end
end
