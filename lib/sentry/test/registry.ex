defmodule Sentry.Test.Registry do
  @moduledoc false

  use GenServer

  require Logger

  # Bypass and Plug.Conn may not be available at compile time (optional deps).
  @compile {:no_warn_undefined,
            [Bypass, Bypass.Instance, Bypass.Supervisor, Plug.Conn, NimbleOwnership]}

  @ownership_server Sentry.Test.OwnershipServer
  @scope_key :sentry_test_scope

  # Rows are 3-tuples `{allowed_pid, owner_pid, processor_name_or_nil}`.
  # `owner_pid` is ALWAYS a pid: only `upsert_owner/2` inserts rows and
  # it always supplies an owner, so the `:DOWN` handler's
  # `:ets.match_delete(_, {:_, owner, :_})` reclaims every row — there
  # are no orphan rows to leak. `processor_name` is `nil` until
  # `tag_processor_for/2` sets it.
  @routing_table :sentry_test_pid_routing

  # Separate ETS table tagging Oban job ids to the test pid that
  # scheduled them, used by the Oban auto-allowance integration.
  @oban_jobs_table :sentry_test_oban_job_tags

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link([] = _opts) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @doc false
  @spec default_dsn :: String.t() | nil
  def default_dsn do
    :persistent_term.get(:sentry_test_default_bypass_dsn, nil)
  end

  # --- Scope ownership metadata: single source of truth ---
  #
  # The NimbleOwnership key under which every test scope is owned. Shared
  # by `Sentry.Test` (collector callback gating) and this module (allow
  # claims) so the literal lives in exactly one place.
  @doc false
  @spec scope_key() :: atom()
  def scope_key, do: @scope_key

  # Metadata stored under `scope_key/0` is ALWAYS a map of shape
  # `%{collector_table: table | nil}`:
  #
  #   * `table` (an ETS table name atom) — a *collecting* scope set up by
  #     `Sentry.Test.setup_collector/1`; events are recorded into `table`.
  #   * `nil` — a *lazy* scope (config-only test that never called
  #     `setup_sentry/1`); no collection.
  #
  # The map is always truthy, satisfying NimbleOwnership's requirement
  # that a key owner has truthy metadata (its `allow/4` treats a pid as
  # an owner only when `state.owners[pid][key]` is truthy). "Collecting
  # vs lazy" is a named field, not an inferred value type.
  @doc false
  @spec collector_metadata(atom()) :: %{collector_table: atom()}
  def collector_metadata(table) when is_atom(table) and not is_nil(table) do
    %{collector_table: table}
  end

  @doc false
  @spec lazy_metadata() :: %{collector_table: nil}
  def lazy_metadata, do: %{collector_table: nil}

  # Extracts the collector table from a metadata value, or `nil` when the
  # scope is lazy / the value is anything unexpected (defensive against
  # legacy/foreign shapes). This is THE discriminator both modules use.
  @doc false
  @spec collector_table(term()) :: atom() | nil
  def collector_table(%{collector_table: table}) when is_atom(table) and not is_nil(table) do
    table
  end

  def collector_table(_other), do: nil

  # Resolves the collector table for `owner_pid` directly from the
  # ownership server. Returns the table atom for a collecting scope, or
  # `nil` for a lazy scope / non-owner. Centralizes the key + get_owned +
  # shape decoding so `Sentry.Test` never touches the raw metadata.
  @doc false
  @spec collector_table_for(pid()) :: atom() | nil
  def collector_table_for(owner_pid) when is_pid(owner_pid) do
    case NimbleOwnership.get_owned(@ownership_server, owner_pid, nil) do
      %{} = owned -> collector_table(Map.get(owned, @scope_key))
      _ -> nil
    end
  end

  @doc """
  Atomic claim of `allowed_pid` for `owner_pid`'s scope. Backed by
  `NimbleOwnership.allow/4` against the `:sentry_test_scope` key — the
  ownership server serializes the conflict check, so two concurrent
  async tests cannot both pass a check-and-then-write race for the
  same `allowed_pid`.

  `mode`:
    * `:strict` — return `{:error, {:taken, existing_owner}}` when a
      live peer scope already owns `allowed_pid` (used by the public
      `Sentry.Test.Config.allow/2`, surfaced as `Scope.AllowConflictError`).
    * `:soft`   — return `:skipped` in the same situation (used by the
      auto-allow of globally-supervised pids in `Config.put/1`).

  Idempotent: re-claiming a pid you already own returns `:ok`.

  This routes through the Registry GenServer so that owner monitoring
  (for ETS row cleanup on owner DOWN) and the cache-row write happen
  atomically with the NimbleOwnership claim.

  Raises if NimbleOwnership returns an *unexpected* error (e.g. the
  ownership server is in shared mode). `Sentry.Test` never silently
  degrades an unknown ownership failure: it fails the offending test
  loudly with the real reason rather than risk cross-test leakage.
  """
  @spec claim_allow(pid(), pid(), :strict | :soft) ::
          :ok | :skipped | {:error, {:taken, pid()}}
  def claim_allow(owner_pid, allowed_pid, mode)
      when is_pid(owner_pid) and is_pid(allowed_pid) and mode in [:strict, :soft] do
    case GenServer.call(__MODULE__, {:claim_allow, owner_pid, allowed_pid, mode}) do
      {:error, {:ownership_error, reason}} ->
        raise "Sentry.Test.Registry: NimbleOwnership.allow/4 returned an " <>
                "unexpected error (#{inspect(reason)}) while claiming " <>
                "#{inspect(allowed_pid)} for #{inspect(owner_pid)}. The test " <>
                "ownership server is in a state Sentry.Test cannot safely route " <>
                "around (is it in shared mode?); aborting this claim instead of " <>
                "risking cross-test event leakage."

      reply ->
        reply
    end
  end

  @doc """
  Ensures `owner_pid` is monitored by the registry so that the
  `:DOWN` handler runs cleanup (routing-table prune + scope-state
  erase via `Sentry.Test.Scope.Registry.handle_owner_down/1`) when
  the owner exits. Idempotent.

  Called from `Sentry.Test.Scope.Registry.update/1` on first scope
  creation so cleanup does not depend on `claim_allow` ever being
  invoked for this owner.
  """
  @spec monitor_owner(pid()) :: :ok
  def monitor_owner(owner_pid) when is_pid(owner_pid) do
    GenServer.call(__MODULE__, {:monitor_owner, owner_pid})
  end

  @doc """
  Direct ETS read of the owner that has allowed `allowed_pid`. Returns
  the owner pid if it is still alive and still owns the entry, or `nil`
  for missing/stale claims. Reads bypass the GenServer because ETS
  lookups are atomic and need to be cheap on the config read path.
  """
  @spec lookup_allow_owner(pid()) :: pid() | nil
  def lookup_allow_owner(allowed_pid) when is_pid(allowed_pid) do
    case :ets.whereis(@routing_table) do
      :undefined ->
        nil

      _ref ->
        case :ets.lookup(@routing_table, allowed_pid) do
          [{^allowed_pid, owner, _processor}] when is_pid(owner) ->
            if Process.alive?(owner), do: owner, else: nil

          _ ->
            nil
        end
    end
  end

  @doc """
  Tags `allowed_pid` so that buffered events (logs, metrics) emitted
  from it are routed to `processor_name` rather than the global
  `Sentry.TelemetryProcessor`. Written by `allow_sentry_reports/2`
  and consulted by `Sentry.TelemetryProcessor.processor_name/0`.

  Updates the existing routing row's processor field. If no row exists
  for `allowed_pid` — it isn't owned by this scope (e.g. a `:soft` claim
  was skipped, or the row was already cleaned up) — this is a no-op:
  buffered events fall back to the global `Sentry.TelemetryProcessor`,
  matching the documented behaviour for non-per-test-processor scopes.

  We deliberately do NOT fabricate a row here. An owner-less row would
  never be reclaimed by the owner-`DOWN` cleanup (it match-deletes by
  owner) and would mis-route events for a pid no scope owns. Direct ETS
  write — atomic, no GenServer round-trip.
  """
  @spec tag_processor_for(pid(), atom()) :: :ok
  def tag_processor_for(allowed_pid, processor_name)
      when is_pid(allowed_pid) and is_atom(processor_name) do
    if :ets.whereis(@routing_table) != :undefined do
      _ = :ets.update_element(@routing_table, allowed_pid, {3, processor_name})
    end

    :ok
  end

  @doc """
  Returns the per-test processor name that should receive buffered
  events from `allowed_pid`, or `nil` if the pid is not tagged or
  the routing table is not started (production).
  """
  @spec lookup_processor_for(pid()) :: atom() | nil
  def lookup_processor_for(allowed_pid) when is_pid(allowed_pid) do
    case :ets.whereis(@routing_table) do
      :undefined ->
        nil

      _ ->
        case :ets.lookup(@routing_table, allowed_pid) do
          [{^allowed_pid, _owner, processor_name}]
          when is_atom(processor_name) and not is_nil(processor_name) ->
            processor_name

          _ ->
            nil
        end
    end
  end

  @doc """
  Clears the processor field on every routing row that points at
  `processor_name`. Used by `setup_collector/1`'s `on_exit/1` so a
  test that exits before its allowed pids do does not leave stale
  routing rows pointing at a stopped per-test processor. The owner
  field is preserved so the allow remains intact (subsequent
  buffered events from those pids fall back to the global
  processor — matching pre-change behaviour).
  """
  @spec drop_processor_routing_for(atom()) :: :ok
  def drop_processor_routing_for(processor_name) when is_atom(processor_name) do
    if :ets.whereis(@routing_table) != :undefined do
      ms = [{{:"$1", :"$2", processor_name}, [], [{{:"$1", :"$2", nil}}]}]
      _ = :ets.select_replace(@routing_table, ms)
    end

    :ok
  end

  @doc """
  Tags an inserted Oban job with the pid of the process that scheduled
  it. Used by the `allowance: [Oban]` telemetry handlers in
  `Sentry.Test` to route a worker's captured events back to the
  inserting test under `async: true`.

  Direct ETS write — atomic, no GenServer round-trip.
  """
  @spec tag_oban_job(integer(), pid()) :: :ok
  def tag_oban_job(job_id, owner_pid)
      when is_integer(job_id) and is_pid(owner_pid) do
    if :ets.whereis(@oban_jobs_table) != :undefined do
      :ets.insert(@oban_jobs_table, {job_id, owner_pid})
    end

    :ok
  end

  @doc """
  Returns the pid that tagged `job_id`, or `nil` if the tag is missing
  or the tagging pid is no longer alive.
  """
  @spec lookup_oban_job(integer()) :: pid() | nil
  def lookup_oban_job(job_id) when is_integer(job_id) do
    case :ets.whereis(@oban_jobs_table) do
      :undefined ->
        nil

      _ ->
        case :ets.lookup(@oban_jobs_table, job_id) do
          [{^job_id, pid}] when is_pid(pid) ->
            if Process.alive?(pid), do: pid, else: nil

          [] ->
            nil
        end
    end
  end

  @doc """
  Removes the tag for `job_id`. Called from the `:oban, :job, :stop`
  and `:oban, :job, :exception` handlers.
  """
  @spec untag_oban_job(integer()) :: :ok
  def untag_oban_job(job_id) when is_integer(job_id) do
    if :ets.whereis(@oban_jobs_table) != :undefined do
      :ets.delete(@oban_jobs_table, job_id)
    end

    :ok
  end

  @doc """
  Removes every tag whose owner is `owner_pid`. Used by
  `setup_collector/1`'s `on_exit/1` cleanup so jobs that crashed
  before emitting a `:stop`/`:exception` event don't leave stale tags
  behind.
  """
  @spec drop_oban_tags_for(pid()) :: :ok
  def drop_oban_tags_for(owner_pid) when is_pid(owner_pid) do
    if :ets.whereis(@oban_jobs_table) != :undefined do
      :ets.match_delete(@oban_jobs_table, {:_, owner_pid})
    end

    :ok
  end

  @impl true
  def init(nil) do
    _routing_table = :ets.new(@routing_table, [:named_table, :public, :set])
    _oban_jobs_table = :ets.new(@oban_jobs_table, [:named_table, :public, :set])
    maybe_start_default_bypass()
    {:ok, %{owner_monitors: %{}}}
  end

  # Serialization note: every claim funnels through this single named
  # GenServer and holds it across TWO blocking round-trips to the
  # ownership server — `ensure_scope_owner/1`'s
  # `NimbleOwnership.get_and_update/4` and `NimbleOwnership.allow/4`.
  # This is the deliberate price of atomicity (no two concurrent async
  # tests can both pass a check-then-write race for the same
  # `allowed_pid`). It is acceptable because claims happen at test
  # setup, not per event, and the hot config/buffer read paths
  # (`lookup_allow_owner/1`, `lookup_processor_for/1`) bypass this
  # GenServer with lock-free direct ETS reads.
  @impl true
  def handle_call({:claim_allow, owner_pid, allowed_pid, mode}, _from, state) do
    state = ensure_owner_monitored(state, owner_pid)

    reply =
      case ensure_scope_owner(owner_pid) do
        {:error, {:taken, existing_owner}} ->
          if mode == :strict, do: {:error, {:taken, existing_owner}}, else: :skipped

        :ok ->
          nimble_allow(owner_pid, allowed_pid, mode, _retry? = true)
      end

    {:reply, reply, state}
  end

  def handle_call({:monitor_owner, owner_pid}, _from, state) do
    state = ensure_owner_monitored(state, owner_pid)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    if :ets.whereis(@routing_table) != :undefined do
      :ets.match_delete(@routing_table, {:_, pid, :_})
    end

    Sentry.Test.Scope.Registry.handle_owner_down(pid)

    {:noreply, %{state | owner_monitors: Map.delete(state.owner_monitors, pid)}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  ## Private helpers

  # Performs the NimbleOwnership claim and maps its result onto the
  # `claim_allow/3` contract. When the pid is reported as already
  # allowed by a *dead* owner whose `:DOWN` the ownership server has
  # not yet processed, that stale owner is evicted synchronously
  # (`NimbleOwnership.cleanup_owner/2`) and the claim is retried once.
  # This restores the pre-NimbleOwnership behaviour where a dead
  # owner's entry was replaced in place, keeping `:strict` re-claims
  # of a pid whose prior owner just exited deterministic instead of
  # racing the asynchronous `:DOWN`.
  defp nimble_allow(owner_pid, allowed_pid, mode, retry?) do
    case NimbleOwnership.allow(@ownership_server, owner_pid, allowed_pid, @scope_key) do
      # `:ok` covers both a fresh allow and an idempotent re-claim of a
      # pid this owner already allows: NimbleOwnership returns `:ok` (not
      # an error) for a same-owner re-allow, and only reports
      # `{:already_allowed, x}` when `x` is a *different* owner. Combined
      # with `ensure_scope_owner/1` guaranteeing `owner_pid` is the
      # resolved key owner before we get here, there is no
      # `{:already_allowed, ^owner_pid}` case that can ever match.
      :ok ->
        upsert_owner(allowed_pid, owner_pid)
        :ok

      {:error, %{reason: {:already_allowed, other}}} ->
        if retry? and not Process.alive?(other) do
          _ = NimbleOwnership.cleanup_owner(@ownership_server, other)
          nimble_allow(owner_pid, allowed_pid, mode, false)
        else
          if mode == :strict, do: {:error, {:taken, other}}, else: :skipped
        end

      {:error, %{reason: :already_an_owner}} ->
        # `allowed_pid` is itself a scope owner — treat as a conflict.
        if mode == :strict, do: {:error, {:taken, allowed_pid}}, else: :skipped

      {:error, %{reason: :not_allowed}} ->
        if mode == :strict, do: {:error, {:taken, allowed_pid}}, else: :skipped

      # Catch-all for any other NimbleOwnership error (e.g.
      # `:cant_allow_in_shared_mode` if the ownership server is ever put
      # in shared mode, or a future library reason). Two failure modes
      # to avoid:
      #
      #   1. Letting the `case` raise here would crash THIS shared,
      #      supervised GenServer; its `init/1` recreates the routing
      #      ETS table, so every in-flight async test loses its routing
      #      — a suite-wide cascade.
      #   2. Degrading to `:skipped`/`{:taken, _}` would either silently
      #      drop the claim (soft: events mysteriously uncollected) or
      #      raise a confidently-WRONG "already allowed by another scope"
      #      diagnostic (strict), burying the real reason.
      #
      # Neither is acceptable for test-isolation infra, so reply with a
      # distinct marker and let `claim_allow/3` raise IN THE CALLER with
      # the true reason: the offending test fails fast and accurately,
      # while the GenServer and every other test stay intact.
      {:error, %{reason: reason}} ->
        {:error, {:ownership_error, reason}}
    end
  end

  defp ensure_owner_monitored(%{owner_monitors: monitors} = state, pid) do
    if Map.has_key?(monitors, pid) do
      state
    else
      ref = Process.monitor(pid)
      %{state | owner_monitors: Map.put(monitors, pid, ref)}
    end
  end

  # Lazily registers `owner_pid` as the NimbleOwnership owner of
  # `scope_key/0` so subsequent `NimbleOwnership.allow/4` calls against
  # this owner succeed even when the test never went through
  # `Sentry.Test.setup_collector/1` (e.g. a test that uses
  # `Sentry.Test.Config.put/1` standalone).
  #
  # The metadata is the canonical `%{collector_table: table | nil}` shape
  # (see `collector_metadata/1` / `lazy_metadata/0`). A lazy scope stores
  # `lazy_metadata/0` (table `nil`). An existing value MUST be preserved
  # (`current -> {:ok, current}`) so a collecting scope set up by
  # `setup_collector/1` is never downgraded to lazy.
  defp ensure_scope_owner(owner_pid) do
    case NimbleOwnership.get_and_update(
           @ownership_server,
           owner_pid,
           @scope_key,
           fn
             nil -> {:ok, lazy_metadata()}
             current -> {:ok, current}
           end
         ) do
      {:ok, _} ->
        :ok

      {:error, %{reason: {:already_allowed, existing_owner}}} ->
        {:error, {:taken, existing_owner}}

      {:error, _} ->
        :ok
    end
  end

  defp upsert_owner(allowed_pid, owner_pid) do
    unless :ets.update_element(@routing_table, allowed_pid, {2, owner_pid}) do
      :ets.insert(@routing_table, {allowed_pid, owner_pid, nil})
    end

    :ok
  end

  # Starts a global Bypass instance that acts as a silent HTTP sink for all tests.
  # This ensures every test has a valid DSN even without calling setup_sentry/1,
  # preserving backward compatibility where capture_* returns {:ok, ""}.
  #
  # In test mode we always override any externally-configured DSN (for example
  # one leaking in from the SENTRY_DSN environment variable), so that running
  # the test suite can never accidentally ship synthetic events to a real
  # Sentry endpoint. When an override happens, we emit a Logger.warning so the
  # developer sees exactly what is being replaced and why.
  defp maybe_start_default_bypass do
    if Code.ensure_loaded?(Bypass) do
      {:ok, _apps} = Application.ensure_all_started(:bypass)

      {:ok, pid} =
        DynamicSupervisor.start_child(
          Bypass.Supervisor,
          Bypass.Instance.child_spec([])
        )

      port = Bypass.Instance.call(pid, :port)
      bypass = struct!(Bypass, pid: pid, port: port)

      # Stub with empty ID to match master's {:ok, ""} return value
      Bypass.stub(bypass, "POST", "/api/1/envelope/", fn conn ->
        Plug.Conn.resp(conn, 200, ~s<{"id": ""}>)
      end)

      dsn_string = "http://public:secret@localhost:#{port}/1"
      maybe_warn_about_dsn_override(dsn_string)

      :persistent_term.put(:sentry_test_default_bypass_dsn, dsn_string)
      Sentry.put_config(:dsn, dsn_string)
    end
  end

  @doc false
  @spec maybe_warn_about_dsn_override(String.t()) :: :ok
  def maybe_warn_about_dsn_override(new_dsn) do
    case Sentry.Config.dsn() do
      %Sentry.DSN{original_dsn: existing} ->
        Logger.warning("""
        [Sentry] test_mode is enabled but a DSN was already configured \
        (#{inspect(existing)}). Overriding it with the local Bypass sink at \
        #{new_dsn} to prevent test events from being sent to a real Sentry \
        endpoint. If this DSN came from the SENTRY_DSN environment variable, \
        unset it for test runs or set :dsn explicitly in your test config.\
        """)

        :ok

      nil ->
        :ok

      _other ->
        :ok
    end
  end
end
