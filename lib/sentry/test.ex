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

  ## Assertion Helpers

  See `Sentry.Test.Assertions` for convenient assertion functions that reduce
  boilerplate when validating captured events, transactions, and logs.

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

    # Open a per-test Bypass and stub the envelope endpoint
    bypass = Bypass.open()

    Bypass.stub(bypass, "POST", "/api/1/envelope/", fn conn ->
      Plug.Conn.resp(conn, 200, ~s<{"id": "#{Sentry.UUID.uuid4_hex()}"}>)
    end)

    # Set up collector with DSN pointing to this test's Bypass
    bypass_config = [dsn: "http://public:secret@localhost:#{bypass.port}/1"]
    setup_collector(bypass_config ++ extra_config)

    %{bypass: bypass}
  end

  @doc """
  Starts collecting events from the current process.

  This function configures Sentry for testing using the default Bypass
  instance (started at application boot). It can be used as an ExUnit
  setup callback:

      setup :start_collecting_sentry_reports

  The `context` parameter is ignored — it exists so this function can be used
  as an ExUnit setup callback.
  """
  @doc since: "10.2.0"
  @spec start_collecting_sentry_reports(map()) :: :ok
  def start_collecting_sentry_reports(_context \\ %{}) do
    unless Process.get(:sentry_test_collector) do
      setup_collector([])
    end

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
      setup_collector([])
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

  @doc """
  Pops all the collected metrics from the current process.

  Returns a list of all `Sentry.Metric` structs that have been collected.
  After this function returns, the collected metrics are cleared but
  collection continues.

  > #### Metrics are Asynchronous {: .info}
  >
  > Metric events flow through the `TelemetryProcessor` pipeline asynchronously.
  > You may need to add a small delay before calling this function to ensure
  > all metrics have been processed by the `before_send_metric` callback.

  """
  @doc since: "13.0.0"
  @spec pop_sentry_metrics(pid()) :: [Sentry.Metric.t()]
  def pop_sentry_metrics(owner_pid \\ self()) when is_pid(owner_pid) do
    pop_by_struct_type(Sentry.Metric)
  end

  # Bypass envelope helpers

  @doc """
  Sets up a Bypass envelope collector that forwards envelope bodies
  to the test process as messages.

  Uses `Bypass.stub` (not `Bypass.expect`) to be resilient to stray requests
  from background processes (e.g., OpenTelemetry span processor).

  Use with `collect_envelopes/3` to retrieve the decoded envelopes.

  ## Options

    * `:type` - when set, only envelopes containing an item of this type
      (e.g., `"event"`, `"transaction"`, `"log"`) are forwarded to the test
      process. Envelopes not matching the type are silently dropped.

  """
  @doc since: "12.1.0"
  @spec setup_bypass_envelope_collector(term(), keyword()) :: reference()
  def setup_bypass_envelope_collector(bypass, opts \\ []) do
    test_pid = self()
    ref = make_ref()
    type_filter = Keyword.get(opts, :type)

    Bypass.stub(bypass, "POST", "/api/1/envelope/", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      if is_nil(type_filter) or body =~ ~s("type":"#{type_filter}") do
        send(test_pid, {:bypass_envelope, ref, body})
      end

      Plug.Conn.resp(conn, 200, ~s<{"id": "#{Sentry.UUID.uuid4_hex()}"}>)
    end)

    ref
  end

  @doc """
  Collects decoded envelopes sent to a Bypass collector.

  Returns a list of decoded envelope item lists. Each element is the result
  of `decode_envelope!/1` for one HTTP request.

  ## Options

    * `:timeout` - timeout in ms to wait for each envelope (default: 1000)

  """
  @doc since: "12.1.0"
  @spec collect_envelopes(reference(), pos_integer(), keyword()) :: [[{map(), map()}]]
  def collect_envelopes(ref, expected_count, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 1000)
    do_collect_envelopes(ref, expected_count, [], timeout)
  end

  defp do_collect_envelopes(_ref, 0, acc, _timeout), do: Enum.reverse(acc)

  defp do_collect_envelopes(ref, remaining, acc, timeout) do
    receive do
      {:bypass_envelope, ^ref, body} ->
        items = decode_envelope!(body)
        do_collect_envelopes(ref, remaining - 1, [items | acc], timeout)
    after
      timeout ->
        Enum.reverse(acc)
    end
  end

  @doc """
  Extracts event payloads from decoded envelope item lists.
  """
  @doc since: "12.1.0"
  @spec extract_events([[{map(), map()}]]) :: [map()]
  def extract_events(envelope_items_list) do
    for items <- envelope_items_list,
        {%{"type" => "event"}, payload} <- items,
        do: payload
  end

  @doc """
  Extracts transaction payloads from decoded envelope item lists.
  """
  @doc since: "12.1.0"
  @spec extract_transactions([[{map(), map()}]]) :: [map()]
  def extract_transactions(envelope_items_list) do
    for items <- envelope_items_list,
        {%{"type" => "transaction"}, payload} <- items,
        do: payload
  end

  @doc """
  Extracts log item payloads from decoded envelope item lists.
  """
  @doc since: "12.1.0"
  @spec extract_log_items([[{map(), map()}]]) :: [map()]
  def extract_log_items(envelope_items_list) do
    for items <- envelope_items_list,
        {%{"type" => "log"}, payload} <- items,
        do: payload
  end

  @doc """
  Extracts check-in payloads from decoded envelope item lists.
  """
  @doc since: "13.0.0"
  @spec extract_check_ins([[{map(), map()}]]) :: [map()]
  def extract_check_ins(envelope_items_list) do
    for items <- envelope_items_list,
        {%{"type" => "check_in"}, payload} <- items,
        do: payload
  end

  @doc """
  Extracts metric batch payloads from decoded envelope item lists.

  Each returned map has an `"items"` key containing the individual
  metric maps for that batch. This mirrors the structure of `extract_log_items/1`.
  """
  @doc since: "13.0.0"
  @spec extract_metric_items([[{map(), map()}]]) :: [map()]
  def extract_metric_items(envelope_items_list) do
    for items <- envelope_items_list,
        {%{"type" => "trace_metric"}, payload} <- items,
        do: payload
  end

  @doc """
  Collects events sent through a Bypass envelope collector.

  This is a high-level helper combining `collect_envelopes/3` and `extract_events/1`.
  Use this instead of `collect_envelopes(ref, count) |> extract_events()`.

  ## Options

    * `:timeout` - timeout in ms to wait for each envelope (default: 1000)

  ## Examples

      ref = setup_bypass_envelope_collector(bypass)
      trigger_event()
      [event] = collect_sentry_events(ref, 1)

  """
  @doc since: "13.0.0"
  @spec collect_sentry_events(reference(), pos_integer(), keyword()) :: [map()]
  def collect_sentry_events(ref, expected_count, opts \\ []) do
    collect_envelopes(ref, expected_count, opts) |> extract_events()
  end

  @doc """
  Collects transactions sent through a Bypass envelope collector.

  This is a high-level helper combining `collect_envelopes/3` and `extract_transactions/1`.
  Use this instead of `collect_envelopes(ref, count) |> extract_transactions()`.

  ## Options

    * `:timeout` - timeout in ms to wait for each envelope (default: 1000)

  ## Examples

      ref = setup_bypass_envelope_collector(bypass)
      run_traced_job()
      [tx] = collect_sentry_transactions(ref, 1)

  """
  @doc since: "13.0.0"
  @spec collect_sentry_transactions(reference(), pos_integer(), keyword()) :: [map()]
  def collect_sentry_transactions(ref, expected_count, opts \\ []) do
    collect_envelopes(ref, expected_count, opts) |> extract_transactions()
  end

  @doc """
  Collects log items sent through a Bypass envelope collector.

  This is a high-level helper combining `collect_envelopes/3` and `extract_log_items/1`.
  Use this instead of `collect_envelopes(ref, count) |> extract_log_items()`.

  ## Options

    * `:timeout` - timeout in ms to wait for each envelope (default: 1000)

  ## Examples

      ref = setup_bypass_envelope_collector(bypass)
      Logger.info("something happened")
      [log] = collect_sentry_logs(ref, 1)

  """
  @doc since: "13.0.0"
  @spec collect_sentry_logs(reference(), pos_integer(), keyword()) :: [map()]
  def collect_sentry_logs(ref, expected_count, opts \\ []) do
    collect_envelopes(ref, expected_count, opts) |> extract_log_items()
  end

  @doc """
  Collects check-in payloads sent through a Bypass envelope collector.

  This is a high-level helper combining `collect_envelopes/3` and `extract_check_ins/1`.
  Use this instead of manually destructuring `[[{header, body}]]` from `collect_envelopes/3`.

  ## Options

    * `:timeout` - timeout in ms to wait for each envelope (default: 1000)

  ## Examples

      ref = setup_bypass_envelope_collector(bypass, type: "check_in")
      Sentry.capture_check_in(status: :ok, monitor_slug: "my-job")
      [check_in] = collect_sentry_check_ins(ref, 1)
      assert check_in["status"] == "ok"

  """
  @doc since: "13.0.0"
  @spec collect_sentry_check_ins(reference(), pos_integer(), keyword()) :: [map()]
  def collect_sentry_check_ins(ref, expected_count, opts \\ []) do
    collect_envelopes(ref, expected_count, opts) |> extract_check_ins()
  end

  @doc """
  Collects metric batch payloads sent through a Bypass envelope collector.

  This is a high-level helper combining `collect_envelopes/3` and `extract_metric_items/1`.
  Use this instead of `collect_envelopes(ref, count) |> extract_metric_items()`.

  Each returned map has an `"items"` key containing the individual metric maps.

  ## Options

    * `:timeout` - timeout in ms to wait for each envelope (default: 1000)

  ## Examples

      ref = setup_bypass_envelope_collector(bypass, type: "trace_metric")
      Sentry.Metrics.count("button.clicks", 1)
      [batch] = collect_sentry_metric_items(ref, 1)
      [metric] = batch["items"]
      assert metric["name"] == "button.clicks"

  """
  @doc since: "13.0.0"
  @spec collect_sentry_metric_items(reference(), pos_integer(), keyword()) :: [map()]
  def collect_sentry_metric_items(ref, expected_count, opts \\ []) do
    collect_envelopes(ref, expected_count, opts) |> extract_metric_items()
  end

  @doc """
  Decodes a raw envelope binary into a list of `{header, item}` tuples.
  """
  @doc since: "12.1.0"
  @spec decode_envelope!(binary()) :: [{header :: map(), item :: map()}]
  def decode_envelope!(binary) do
    json_library = Sentry.Config.json_library()
    [id_line | rest] = String.split(binary, "\n")
    {:ok, %{"event_id" => _}} = Sentry.JSON.decode(id_line, json_library)

    rest
    |> Enum.chunk_every(2)
    |> Enum.flat_map(fn
      [header, item] ->
        {:ok, decoded_header} = Sentry.JSON.decode(header, json_library)
        {:ok, decoded_item} = Sentry.JSON.decode(item, json_library)
        [{decoded_header, decoded_item}]

      [""] ->
        []
    end)
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

  # Sets up collection infrastructure (ETS table, before_send wrapping, config)
  # without opening a new Bypass. When no :dsn is provided in extra_config,
  # falls back to the default Bypass DSN from Registry.
  defp setup_collector(extra_config) do
    uid = System.unique_integer([:positive])
    collector_table = :"sentry_test_collector_#{uid}"
    :ets.new(collector_table, [:ordered_set, :public, :named_table])

    # Register this test's collector
    :ets.insert(@registry_table, {self(), collector_table})

    # Store in process dict for pop_* lookups
    Process.put(:sentry_test_collector, collector_table)

    # Extract user-provided callbacks from extra_config (if any), falling back to current config
    {user_before_send, extra_config} = Keyword.pop(extra_config, :before_send)
    {user_before_send_event, extra_config} = Keyword.pop(extra_config, :before_send_event)
    {user_before_send_log, extra_config} = Keyword.pop(extra_config, :before_send_log)
    {user_before_send_metric, extra_config} = Keyword.pop(extra_config, :before_send_metric)

    # Use the caller-only registry lookup instead of `Sentry.Config.before_send/0`
    # so the captured "original" callback is only this test's override (or the
    # global default), never another concurrent test's wrapping callback.
    original_before_send =
      user_before_send || user_before_send_event ||
        original_config_value(:before_send)

    original_before_send_log =
      user_before_send_log || original_config_value(:before_send_log)

    original_before_send_metric =
      user_before_send_metric || original_config_value(:before_send_metric)

    # Build collecting callbacks that wrap the originals
    new_before_send = build_collecting_callback(original_before_send)
    new_before_send_log = build_collecting_callback(original_before_send_log)
    new_before_send_metric = build_collecting_callback(original_before_send_metric)

    # Always set a per-test DSN override. When no DSN is provided, use the
    # default Bypass DSN.
    extra_config =
      if Keyword.has_key?(extra_config, :dsn) do
        extra_config
      else
        case Sentry.Test.Registry.default_dsn() do
          nil -> extra_config
          dsn -> Keyword.put(extra_config, :dsn, dsn)
        end
      end

    config =
      [finch_request_opts: [receive_timeout: 2000]]
      |> Keyword.merge(extra_config)
      |> Keyword.merge(
        before_send: new_before_send,
        before_send_log: new_before_send_log,
        before_send_metric: new_before_send_metric
      )

    put_test_config(config)

    scheduler_pid = get_scheduler_pid()

    if scheduler_pid do
      :ets.insert_new(@registry_table, {scheduler_pid, collector_table})
    end

    # Register cleanup
    test_pid = self()

    ExUnit.Callbacks.on_exit(fn ->
      if :ets.whereis(@registry_table) != :undefined do
        :ets.delete(@registry_table, test_pid)

        if scheduler_pid do
          case :ets.lookup(@registry_table, scheduler_pid) do
            [{^scheduler_pid, ^collector_table}] ->
              :ets.delete(@registry_table, scheduler_pid)

            _ ->
              :ok
          end
        end
      end

      if :ets.whereis(collector_table) != :undefined do
        :ets.delete(collector_table)
      end
    end)

    :ok
  end

  defp get_scheduler_pid do
    processor =
      Process.get(:sentry_telemetry_processor, Sentry.TelemetryProcessor.default_name())

    scheduler_name = Sentry.TelemetryProcessor.scheduler_name(processor)
    GenServer.whereis(scheduler_name)
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
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

  # Reads `key` from this test's per-process scope (or any caller's scope on
  # `[self() | $callers]`), falling back to the global config value. Skips the
  # full namespace resolver so the captured "original" callback is never
  # another concurrent test's wrapping callback.
  defp original_config_value(key) do
    case Sentry.Test.Scope.Registry.lookup_caller_override(key) do
      {:ok, value} -> value
      :default -> :persistent_term.get({:sentry_config, key}, nil)
    end
  end

  defp build_collecting_callback(nil) do
    fn struct ->
      case find_collector() do
        nil -> :ok
        table -> collect_struct(table, struct)
      end

      struct
    end
  end

  defp build_collecting_callback({mod, fun}) do
    build_collecting_callback(Function.capture(mod, fun, 1))
  end

  defp build_collecting_callback(original) when is_function(original, 1) do
    fn struct ->
      # Guard on find_collector/0 so that a test-specific callback stored in
      # :persistent_term is never invoked from an unrelated async test's process.
      # When a collector IS found, call the original first so user-defined
      # filtering/modification is applied before we collect the result.
      case find_collector() do
        nil ->
          struct

        table ->
          result = original.(struct)
          unless is_nil(result), do: collect_struct(table, result)
          result
      end
    end
  end

  defp collect_struct(table, struct) do
    :ets.insert(table, {System.unique_integer([:monotonic]), struct})
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
