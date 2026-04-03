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

  Per-test overrides are stored in `:persistent_term` keyed by `{:sentry_config, test_pid, key}`.
  The `namespace/1` function walks the current process's caller chain (`$callers`) to find
  overrides set by the test process, so child processes (e.g., `Task`s) automatically
  inherit the test's configuration.

  For processes that don't have `$callers` pointing to the test process (such as
  GenServers started via `start_supervised!/1`), use `allow/2` to explicitly grant
  them access to the test's configuration.

  Overrides are automatically cleaned up when the test exits via `ExUnit.Callbacks.on_exit/1`.
  """

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
    end

    :ok
  end

  @doc """
  Resolves config namespace for the current process.

  The resolution order is:

  1. Walks `[self() | Process.get(:"$callers", [])]` looking for per-test overrides.
  2. Checks whether the process was explicitly allowed via `allow/2`.
  3. As a last resort, scans all active test scopes (registered via `put/1`).
     This fallback only applies when exactly one scope is active, making it
     safe for `async: false` tests only.

  Returns `{:ok, value}` if an override is found, or `:default` to fall back
  to global configuration.
  """
  @spec namespace(atom()) :: {:ok, term()} | :default
  def namespace(key) do
    scopes = [self() | Process.get(:"$callers", [])]

    case find_override(scopes, key) do
      {:ok, _value} = found ->
        found

      :default ->
        # Check if this process was explicitly allowed by a test process via allow/2.
        case :persistent_term.get({:sentry_test_config_allowed, self()}, nil) do
          nil ->
            # Last resort: scan all active test scopes (safe only for async: false tests).
            resolve_from_active_scopes(key)

          owner_pid ->
            find_override([owner_pid], key)
        end
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
    test_pid = self()

    original_config =
      for {key, val} <- config do
        renamed_key =
          case key do
            :before_send_event -> :before_send
            other -> other
          end

        validated_config = Sentry.Config.validate!([{renamed_key, val}])
        validated_val = Keyword.fetch!(validated_config, renamed_key)

        :persistent_term.put({:sentry_config, test_pid, renamed_key}, validated_val)

        {renamed_key, validated_val}
      end

    register_scope(test_pid)

    ExUnit.Callbacks.on_exit(fn ->
      for {key, _val} <- original_config do
        :persistent_term.erase({:sentry_config, test_pid, key})
      end

      unregister_scope(test_pid)
    end)

    :ok
  end

  @doc """
  Allows `allowed_pid` to read the configuration of `owner_pid`'s test scope.

  Use this when a supervised process (such as a `GenServer` started via
  `start_supervised!/1`) does not inherit the test process's `$callers` chain
  and therefore cannot resolve per-test configuration overrides on its own.

  The mapping is automatically cleaned up when the test exits.

  ## Example

      scheduler_pid = Sentry.TelemetryProcessor.get_scheduler(processor_name)
      Sentry.Test.Config.allow(self(), scheduler_pid)

  """
  @spec allow(pid(), pid()) :: :ok
  def allow(owner_pid, allowed_pid) do
    :persistent_term.put({:sentry_test_config_allowed, allowed_pid}, owner_pid)

    ExUnit.Callbacks.on_exit(fn ->
      :persistent_term.erase({:sentry_test_config_allowed, allowed_pid})
    end)

    :ok
  end

  ## Private helpers

  defp find_override(scopes, key) do
    Enum.find_value(scopes, :default, fn pid ->
      case :persistent_term.get({:sentry_config, pid, key}, :__not_set__) do
        :__not_set__ -> nil
        value -> {:ok, value}
      end
    end)
  end

  defp resolve_from_active_scopes(key) do
    overrides =
      for {{:sentry_test_config_scope, pid}, true} <- :persistent_term.get(),
          Process.alive?(pid),
          value = :persistent_term.get({:sentry_config, pid, key}, :__not_set__),
          value != :__not_set__,
          do: value

    case overrides do
      [single_value] -> {:ok, single_value}
      _zero_or_ambiguous -> :default
    end
  end

  defp register_scope(pid) do
    :persistent_term.put({:sentry_test_config_scope, pid}, true)
  end

  defp unregister_scope(pid) do
    :persistent_term.erase({:sentry_test_config_scope, pid})
  end
end
