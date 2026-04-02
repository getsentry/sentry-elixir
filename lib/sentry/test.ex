defmodule Sentry.Test do
  @moduledoc """
  Utilities for testing Sentry reports.

  ## Usage

  This module provides helpers that set up a local HTTP server (via Bypass) so that
  Sentry SDK calls in your tests hit a local endpoint instead of the real Sentry API.
  Events are captured via the existing `before_send` and `before_send_log` callbacks
  and stored in an isolated ETS table per test, preserving the full struct data.

  > #### Bypass Required {: .info}
  >
  > This module requires `bypass` as a test dependency:
  >
  >     {:bypass, "~> 2.0", only: [:test]}

  ## Examples

  The simplest way to use this module is with the `setup_sentry/1` function:

      defmodule MyApp.ErrorReportingTest do
        use ExUnit.Case, async: true

        setup do
          Sentry.Test.setup_sentry()
        end

        test "reports exceptions to Sentry" do
          try do
            raise "boom"
          rescue
            e -> Sentry.capture_exception(e)
          end

          assert [%Sentry.Event{} = event] = Sentry.Test.pop_sentry_reports()
          assert event.original_exception == %RuntimeError{message: "boom"}
        end
      end

  You can also use `start_collecting_sentry_reports/0` as an ExUnit setup callback
  for backwards compatibility:

      setup :start_collecting_sentry_reports

  """

  @moduledoc since: "10.2.0"

  @compile {:no_warn_undefined, [Bypass, Plug.Conn]}

  @registry_table :sentry_test_collectors

  # Public API

  @doc """
  Sets up a Bypass instance and configures Sentry for testing.

  Opens a Bypass on a random port, configures the DSN to point to it,
  and wires up `before_send` / `before_send_log` callbacks to capture
  structs in an isolated ETS table.

  Returns a map with `:bypass` for use in test context.

  ## Options

  Any extra Sentry config options (e.g., `dedup_events: false`, `traces_sample_rate: 1.0`)
  will be forwarded to the test config.

  ## Examples

      setup do
        Sentry.Test.setup_sentry()
      end

      setup do
        Sentry.Test.setup_sentry(dedup_events: false)
      end

  """
  @doc since: "12.1.0"
  @spec setup_sentry(keyword()) :: %{bypass: term()}
  def setup_sentry(extra_config \\ []) do
    ensure_bypass_loaded!()
    ensure_registry!()

    # Create a unique collector ETS table for this test
    uid = System.unique_integer([:positive])
    collector_table = :"sentry_test_collector_#{uid}"
    :ets.new(collector_table, [:ordered_set, :public, :named_table])

    # Register this test's collector
    :ets.insert(@registry_table, {self(), collector_table})

    # Store in process dict for pop_* lookups
    Process.put(:sentry_test_collector, collector_table)

    # Open Bypass and stub the envelope endpoint
    bypass = Bypass.open()

    Bypass.stub(bypass, "POST", "/api/1/envelope/", fn conn ->
      Plug.Conn.resp(conn, 200, ~s<{"id": "#{Sentry.UUID.uuid4_hex()}"}>)
    end)

    # Extract user-provided callbacks from extra_config (if any), falling back to current config
    {user_before_send, extra_config} = Keyword.pop(extra_config, :before_send)
    {user_before_send_event, extra_config} = Keyword.pop(extra_config, :before_send_event)
    {user_before_send_log, extra_config} = Keyword.pop(extra_config, :before_send_log)

    original_before_send =
      user_before_send || user_before_send_event || Sentry.Config.before_send()

    original_before_send_log = user_before_send_log || Sentry.Config.before_send_log()

    # Build collecting callbacks that wrap the originals
    new_before_send = build_collecting_callback(original_before_send)
    new_before_send_log = build_collecting_callback(original_before_send_log)

    # Configure DSN + callbacks + any extra config
    config =
      extra_config
      |> Keyword.merge(
        dsn: "http://public:secret@localhost:#{bypass.port}/1",
        before_send: new_before_send,
        before_send_log: new_before_send_log
      )

    put_test_config(config)

    # Register cleanup
    test_pid = self()

    ExUnit.Callbacks.on_exit(fn ->
      if :ets.whereis(@registry_table) != :undefined do
        :ets.delete(@registry_table, test_pid)
      end

      if :ets.whereis(collector_table) != :undefined do
        :ets.delete(collector_table)
      end
    end)

    %{bypass: bypass}
  end

  @doc """
  Starts collecting events from the current process.

  This function sets up Bypass and configures Sentry for testing.
  It can be used as an ExUnit setup callback:

      setup :start_collecting_sentry_reports

  The `context` parameter is ignored — it exists so this function can be used
  as an ExUnit setup callback.
  """
  @doc since: "10.2.0"
  @spec start_collecting_sentry_reports(map()) :: :ok
  def start_collecting_sentry_reports(_context \\ %{}) do
    setup_sentry()
    :ok
  end

  @doc """
  Starts collecting events.

  > #### Deprecated {: .warning}
  >
  > This function is deprecated and will be removed in v13.0.0.
  > Use `setup_sentry/1` or `start_collecting_sentry_reports/0` instead.

  The `:owner`, `:cleanup`, and `:key` options are no longer supported and are ignored.
  """
  @doc since: "10.2.0"
  @doc deprecated: "Use setup_sentry/1 or start_collecting_sentry_reports/0 instead"
  @spec start_collecting(keyword()) :: :ok
  def start_collecting(_options \\ []) do
    # Ensure setup has been called; if not, set it up now
    unless Process.get(:sentry_test_collector) do
      setup_sentry()
    end

    :ok
  end

  @doc """
  Cleans up test resources associated with `owner_pid`.

  > #### Deprecated {: .warning}
  >
  > This function is deprecated and will be removed in v13.0.0.
  > Cleanup is now handled automatically via `on_exit` callbacks.
  """
  @doc since: "10.2.0"
  @doc deprecated: "Cleanup is now automatic via on_exit callbacks"
  @spec cleanup(pid()) :: :ok
  def cleanup(owner_pid) when is_pid(owner_pid) do
    :ok
  end

  @doc """
  Allows `pid_to_allow` to collect events back to the root process via `owner_pid`.

  > #### Deprecated {: .warning}
  >
  > This function is deprecated and will be removed in v13.0.0.
  > Child processes are automatically tracked via the `$callers` mechanism.
  > There is no need to explicitly allow processes.
  """
  @doc since: "10.2.0"
  @doc deprecated: "Child processes are now automatically tracked via $callers"
  @spec allow_sentry_reports(pid(), pid() | (-> pid())) :: :ok
  def allow_sentry_reports(_owner_pid, _pid_to_allow) do
    :ok
  end

  @doc """
  Pops all the collected events from the current process.

  Returns a list of all `Sentry.Event` structs that have been collected from the
  current process and all child processes spawned from it. After this function
  returns, the collected events are cleared but collection continues.

  ## Examples

      iex> Sentry.Test.start_collecting_sentry_reports()
      :ok
      iex> Sentry.capture_message("Oops")
      {:ok, ""}
      iex> [%Sentry.Event{} = event] = Sentry.Test.pop_sentry_reports()
      iex> event.message.formatted
      "Oops"

  """
  @doc since: "10.2.0"
  @spec pop_sentry_reports(pid()) :: [Sentry.Event.t()]
  def pop_sentry_reports(owner_pid \\ self()) when is_pid(owner_pid) do
    pop_by_struct_type(Sentry.Event)
  end

  @doc """
  Pops all the collected transactions from the current process.

  Returns a list of all `Sentry.Transaction` structs that have been collected.
  After this function returns, the collected transactions are cleared but
  collection continues.

  ## Examples

      iex> Sentry.Test.start_collecting_sentry_reports()
      :ok
      iex> Sentry.send_transaction(Sentry.Transaction.new(%{span_id: "123", start_timestamp: "2024-10-12T13:21:13", timestamp: "2024-10-12T13:21:13", spans: []}))
      {:ok, ""}
      iex> [%Sentry.Transaction{}] = Sentry.Test.pop_sentry_transactions()

  """
  @doc since: "10.2.0"
  @spec pop_sentry_transactions(pid()) :: [Sentry.Transaction.t()]
  def pop_sentry_transactions(owner_pid \\ self()) when is_pid(owner_pid) do
    pop_by_struct_type(Sentry.Transaction)
  end

  @doc """
  Pops all the collected log events from the current process.

  Returns a list of all `Sentry.LogEvent` structs that have been collected.
  After this function returns, the collected log events are cleared but
  collection continues.

  > #### Logs are Asynchronous {: .info}
  >
  > Log events flow through the `TelemetryProcessor` pipeline asynchronously.
  > You may need to add a small delay before calling this function to ensure
  > all log events have been processed by the `before_send_log` callback.

  """
  @doc since: "11.0.0"
  @spec pop_sentry_logs(pid()) :: [Sentry.LogEvent.t()]
  def pop_sentry_logs(owner_pid \\ self()) when is_pid(owner_pid) do
    pop_by_struct_type(Sentry.LogEvent)
  end

  # Private helpers

  defp ensure_bypass_loaded! do
    unless Code.ensure_loaded?(Bypass) do
      raise """
      Bypass is required for Sentry.Test but is not available.

      Add it to your test dependencies in mix.exs:

          {:bypass, "~> 2.0", only: [:test]}
      """
    end
  end

  defp ensure_registry! do
    ensure_named_table!(@registry_table, [:named_table, :public, :set])
  end

  defp ensure_named_table!(name, opts) do
    if :ets.whereis(name) == :undefined do
      # Spawn a long-lived process to own the table.
      # ETS tables are destroyed when their owner exits, so we need a process
      # that outlives individual test processes.
      spawn(fn ->
        :ets.new(name, opts)
        Process.hibernate(Function, :identity, [:ok])
      end)

      wait_for_table(name)
    end
  end

  defp wait_for_table(name) do
    if :ets.whereis(name) == :undefined do
      Process.sleep(1)
      wait_for_table(name)
    end
  end

  defp find_collector do
    pids = [self() | Process.get(:"$callers", [])]

    Enum.find_value(pids, fn pid ->
      case :ets.lookup(@registry_table, pid) do
        [{^pid, table}] -> table
        [] -> nil
      end
    end)
  end

  defp build_collecting_callback(nil) do
    fn struct ->
      collect_struct(struct)
      struct
    end
  end

  defp build_collecting_callback(original) when is_function(original, 1) do
    fn struct ->
      # Only call the wrapped user callback when invoked from a process that
      # belongs to the test that set it up. This prevents the callback from
      # leaking to other async tests via :persistent_term.
      case find_collector() do
        nil ->
          struct

        _table ->
          collect_struct(struct)
          original.(struct)
      end
    end
  end

  defp build_collecting_callback({mod, fun}) do
    fn struct ->
      case find_collector() do
        nil ->
          struct

        _table ->
          collect_struct(struct)
          apply(mod, fun, [struct])
      end
    end
  end

  defp collect_struct(struct) do
    case find_collector() do
      nil ->
        :not_collecting

      table ->
        :ets.insert(table, {System.unique_integer([:monotonic]), struct})
        :collected
    end
  end

  defp pop_by_struct_type(struct_module) do
    table =
      Process.get(:sentry_test_collector) ||
        raise ArgumentError,
              "not collecting Sentry reports. Call setup_sentry/1 or start_collecting_sentry_reports/0 first."

    # Read all entries, filter by struct type, delete matched entries
    entries = :ets.tab2list(table)

    {matched, _rest} =
      Enum.split_with(entries, fn {_key, struct} ->
        is_struct(struct, struct_module)
      end)

    # Delete matched entries from ETS
    for {key, _struct} <- matched do
      :ets.delete(table, key)
    end

    # Return structs in insertion order (ordered_set ensures this)
    Enum.map(matched, fn {_key, struct} -> struct end)
  end

  defp put_test_config(config) when is_list(config) do
    Sentry.Test.Config.put(config)
    :ok
  end
end
