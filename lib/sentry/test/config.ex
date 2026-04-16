defmodule Sentry.Test.Config do
  @moduledoc """
  Provides per-test configuration isolation for the Sentry SDK.

  When `test_mode: true` is configured, the SDK automatically uses this module
  as the `:namespace` resolver, enabling tests to override Sentry configuration
  on a per-test basis without affecting other tests, even when running with
  `async: true`.

  ## Usage

  Use `put/1` in your test setup blocks to set per-test configuration overrides:

      setup do
        Sentry.Test.Config.put(dsn: "http://public:secret@localhost:\#{bypass.port}/1")
      end

  ## How It Works

  Each test's overrides live in a `Sentry.Test.Scope` struct stored in
  `:persistent_term` under `{:sentry_test_scope, test_pid}`. The `namespace/1`
  function asks `Sentry.Test.Scope.Registry` to resolve a scope for the
  current process by trying three strategies in order:

    1. Walking `[self() | Process.get(:"$callers", [])]`.
    2. Walking the `:"$ancestors"` chain transitively against each scope's
       `allowed_pids` (populated via `allow/2` and by the auto-allow of
       globally-supervised pids on the first `put/1` call).
    3. Walking the `:"$ancestors"` chain against each scope's owner pid —
       covers GenServers started via `start_supervised/1`.

  Globally-supervised processes (`:logger`, `:logger_sup`,
  `Sentry.Supervisor`) have no caller/ancestor link back to any test.
  `put/1` auto-soft-allows them onto the calling scope so strategy 2
  routes their config queries to the right test transparently, without
  requiring downstream suites to call `allow/2` themselves.

  Overrides are automatically cleaned up when the test exits via
  `ExUnit.Callbacks.on_exit/1`.
  """

  alias Sentry.Test.Scope
  alias Sentry.Test.Scope.Registry

  # Globally-supervised pids that the SDK needs to route per-test config
  # through (log-handler lifecycle + the SDK supervisor). Auto-allowed onto
  # every scope created via `put/1` so downstream test suites do not have
  # to opt in explicitly. Atoms are resolved lazily at auto-allow time via
  # `Process.whereis/1` — they may not be registered when the app boots.
  @auto_allow_globals [:logger, :logger_sup, Sentry.Supervisor]

  @doc """
  Activates per-test configuration isolation if `test_mode: true` is configured
  and no custom `:namespace` resolver has been explicitly set.

  Called automatically by `Sentry.Application` on startup. You do not need to
  call this manually.
  """
  @spec maybe_activate() :: :ok
  def maybe_activate do
    if Sentry.Config.test_mode?() and Sentry.Config.namespace() == {Sentry.Config, :namespace} do
      :persistent_term.put({:sentry_config, :namespace}, {__MODULE__, :namespace})
      Registry.maybe_init()
    end

    :ok
  end

  @doc """
  Resolves config namespace for the current process.

  Returns `{:ok, value}` if an override is found, or `:default` to fall back
  to global configuration.
  """
  @spec namespace(atom()) :: {:ok, term()} | :default
  def namespace(key) do
    case Registry.resolve(self()) do
      {:ok, scope} ->
        case Scope.fetch_override(scope, key) do
          {:ok, value} -> {:ok, value}
          :error -> :default
        end

      :none ->
        :default
    end
  end

  @doc """
  Sets per-test configuration overrides for the current test process.

  Each key-value pair is validated through `Sentry.Config.validate!/1` before
  being stored. Overrides are automatically cleaned up when the test exits.

  ## Example

      setup do
        Sentry.Test.Config.put(
          dsn: "http://public:secret@localhost:\#{bypass.port}/1",
          send_result: :sync
        )
      end

  """
  @spec put(keyword()) :: :ok
  def put(config) when is_list(config) do
    entries = Enum.map(config, &validate_and_rename/1)

    _ =
      Registry.update(self(), fn scope ->
        Enum.reduce(entries, scope, fn {key, value}, acc ->
          Scope.put_override(acc, key, value)
        end)
      end)

    auto_allow_globals()

    :ok
  end

  defp auto_allow_globals do
    owner = self()
    Enum.each(@auto_allow_globals, &Registry.soft_allow(owner, Process.whereis(&1)))
  end

  @doc """
  Allows `allowed_pid` to read the configuration of `owner_pid`'s test scope.

  Use this when a supervised process (such as a `GenServer` started via
  `start_supervised!/1`) does not inherit the test process's `$callers` chain
  and cannot be reached via the `$ancestors` walk (for example, a
  globally-registered process started at application boot).

  The mapping is automatically cleaned up when the test exits.

  ## Example

      scheduler_pid = Sentry.TelemetryProcessor.get_scheduler(processor_name)
      Sentry.Test.Config.allow(self(), scheduler_pid)

  """
  @spec allow(pid(), pid() | nil) :: :ok
  def allow(_owner_pid, nil), do: :ok

  def allow(owner_pid, allowed_pid) when is_pid(owner_pid) and is_pid(allowed_pid) do
    Registry.strict_allow!(owner_pid, allowed_pid)
  end

  ## Private helpers

  defp validate_and_rename({key, value}) do
    renamed =
      case key do
        :before_send_event -> :before_send
        other -> other
      end

    validated = Sentry.Config.validate!([{renamed, value}])
    {renamed, Keyword.fetch!(validated, renamed)}
  end
end
