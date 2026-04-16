defmodule Sentry.Test.Registry do
  @moduledoc false

  use GenServer

  require Logger

  # Bypass and Plug.Conn may not be available at compile time (optional deps).
  @compile {:no_warn_undefined, [Bypass, Bypass.Instance, Bypass.Supervisor, Plug.Conn]}

  @table :sentry_test_collectors
  @allows_table :sentry_test_scope_allows

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link([] = _opts) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @doc false
  @spec default_dsn :: String.t() | nil
  def default_dsn do
    :persistent_term.get(:sentry_test_default_bypass_dsn, nil)
  end

  @doc """
  Atomic claim of `allowed_pid` for `owner_pid`'s scope. All claims
  serialize through this GenServer so the conflict check and the ETS
  write happen as one indivisible step — no two concurrent async tests
  can both pass a check-and-then-write race for the same allowed_pid.

  `mode`:
    * `:strict` — return `{:error, {:taken, existing_owner}}` when a
      live peer scope already owns `allowed_pid` (used by the public
      `Sentry.Test.Config.allow/2`, surfaced as `Scope.AllowConflictError`).
    * `:soft`   — return `:skipped` in the same situation (used by the
      auto-allow of globally-supervised pids in `Config.put/1`).

  Stale entries from owners that have exited without cleanup are
  silently replaced so the new owner can claim the pid.

  Idempotent: re-claiming a pid you already own returns `:ok`.
  """
  @spec claim_allow(pid(), pid(), :strict | :soft) ::
          :ok | :skipped | {:error, {:taken, pid()}}
  def claim_allow(owner_pid, allowed_pid, mode)
      when is_pid(owner_pid) and is_pid(allowed_pid) and mode in [:strict, :soft] do
    GenServer.call(__MODULE__, {:claim_allow, owner_pid, allowed_pid, mode})
  end

  @doc """
  Removes every allow entry whose owner is `owner_pid`. Atomic batch
  delete via `:ets.match_delete/2` — safe to call from a test's on_exit
  cleanup without serializing through the GenServer.
  """
  @spec drop_allows_for(pid()) :: :ok
  def drop_allows_for(owner_pid) when is_pid(owner_pid) do
    if :ets.whereis(@allows_table) != :undefined do
      :ets.match_delete(@allows_table, {:_, owner_pid})
    end

    :ok
  end

  @doc """
  Direct ETS read of the owner that has allowed `allowed_pid`. Returns
  the owner pid if it is still alive and still owns the entry, or `nil`
  for missing/stale claims. Reads bypass the GenServer because ETS
  lookups are atomic and need to be cheap on the config read path.
  """
  @spec lookup_allow_owner(pid()) :: pid() | nil
  def lookup_allow_owner(allowed_pid) when is_pid(allowed_pid) do
    case :ets.whereis(@allows_table) do
      :undefined ->
        nil

      _ref ->
        case :ets.lookup(@allows_table, allowed_pid) do
          [{^allowed_pid, owner}] when is_pid(owner) ->
            if Process.alive?(owner), do: owner, else: nil

          [] ->
            nil
        end
    end
  end

  @impl true
  def init(nil) do
    _table = :ets.new(@table, [:named_table, :public, :set])
    _allows_table = :ets.new(@allows_table, [:named_table, :public, :set])
    maybe_start_default_bypass()
    {:ok, :no_state}
  end

  @impl true
  def handle_call({:claim_allow, owner_pid, allowed_pid, mode}, _from, state) do
    reply =
      case :ets.lookup(@allows_table, allowed_pid) do
        [] ->
          true = :ets.insert_new(@allows_table, {allowed_pid, owner_pid})
          :ok

        [{^allowed_pid, ^owner_pid}] ->
          :ok

        [{^allowed_pid, existing_owner}] ->
          cond do
            not Process.alive?(existing_owner) ->
              true = :ets.insert(@allows_table, {allowed_pid, owner_pid})
              :ok

            mode == :strict ->
              {:error, {:taken, existing_owner}}

            true ->
              :skipped
          end
      end

    {:reply, reply, state}
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
