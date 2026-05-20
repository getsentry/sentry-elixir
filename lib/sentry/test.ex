defmodule Sentry.Test do
  @moduledoc """
  Utilities for testing Sentry reports.

  ## Usage

  This module provides helpers that set up a local HTTP server (via Bypass) so that
  Sentry SDK calls in your tests hit a local endpoint instead of the real Sentry API.
  Events are captured via the existing `before_send` and `before_send_log` callbacks
  and stored in an isolated ETS table per test, preserving the full struct data.

  > #### Bypass and NimbleOwnership Required {: .info}
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

  @ownership_server Sentry.Test.OwnershipServer

  # Public API

  @doc """
  Sets up a Bypass instance and configures Sentry for testing.

  Opens a Bypass on a random port, configures the DSN to point to it,
  wires up `before_send` / `before_send_log` callbacks to capture structs
  in an isolated ETS table, and starts a per-test `Sentry.TelemetryProcessor`
  (via `setup_telemetry_processor/1`) so that assertions work for events
  that travel through the TelemetryProcessor pipeline (logs, metrics, or
  `send_result: :none`).

  Returns a map with `:bypass` and `:telemetry_processor` for use in test
  context. The `:telemetry_processor` value is the atom name of the
  per-test processor and can be used to `stop_supervised!/1` and start
  a custom-configured one when needed.

  ## Options

  Any extra Sentry config options (e.g., `dedup_events: false`, `traces_sample_rate: 1.0`)
  will be forwarded to the test config.

  The reserved `:telemetry_processor` option is *not* forwarded to the test
  config. Instead, its value (a keyword list) is passed to the per-test
  `Sentry.TelemetryProcessor` (e.g. `buffer_configs`, `buffer_capacities`,
  `scheduler_weights`, `transport_capacity`). This replaces the need to
  manually `stop_supervised!/1` and re-`start_supervised!/2` the processor.

  The reserved `:collect_envelopes` option is *not* forwarded to the test
  config either. When set, a Bypass envelope collector is wired up
  automatically and its reference is returned under the `:ref` key:

    * `true` — set up the collector with no options;
    * a keyword list — forwarded to `setup_bypass_envelope_collector/2`
      (e.g. `[type: "check_in"]` to only collect a given item type).

  This collapses the common `bypass = setup_sentry(...); ref =
  setup_bypass_envelope_collector(bypass)` two-step into one call.

  ## Examples

      setup do
        Sentry.Test.setup_sentry()
      end

      setup do
        Sentry.Test.setup_sentry(dedup_events: false)
      end

  Configuring the per-test processor (e.g. a smaller log batch size):

      setup do
        Sentry.Test.setup_sentry(
          telemetry_processor: [buffer_configs: %{log: %{batch_size: 1}}]
        )
      end

  Collecting envelopes directly as the ExUnit setup return:

      setup do
        Sentry.Test.setup_sentry(collect_envelopes: true, traces_sample_rate: 1.0)
      end

      test "...", %{ref: ref} do
        # ...
      end

  """
  @doc since: "13.0.0"
  @spec setup_sentry(keyword()) :: %{
          :bypass => term(),
          :telemetry_processor => atom(),
          optional(:ref) => reference()
        }
  def setup_sentry(extra_config \\ []) do
    ensure_bypass_loaded!()

    {tp_opts, extra_config} = Keyword.pop(extra_config, :telemetry_processor, [])
    {collect_envelopes, extra_config} = Keyword.pop(extra_config, :collect_envelopes, false)

    # Open a per-test Bypass and stub the envelope endpoint
    bypass = Bypass.open()

    Bypass.stub(bypass, "POST", "/api/1/envelope/", fn conn ->
      Plug.Conn.resp(conn, 200, ~s<{"id": "#{Sentry.UUID.uuid4_hex()}"}>)
    end)

    # Start a per-test TelemetryProcessor before setup_collector/1 so that
    # the collector wires this test's scheduler into its registry.
    processor_name = setup_telemetry_processor(tp_opts)

    # Set up collector with DSN pointing to this test's Bypass
    bypass_config = [dsn: "http://public:secret@localhost:#{bypass.port}/1"]
    setup_collector(bypass_config ++ extra_config)

    case collect_envelopes do
      false ->
        %{bypass: bypass, telemetry_processor: processor_name}

      collect ->
        collector_opts = if is_list(collect), do: collect, else: []

        %{
          bypass: bypass,
          telemetry_processor: processor_name,
          ref: setup_bypass_envelope_collector(bypass, collector_opts)
        }
    end
  end

  @doc """
  Starts an isolated, per-test `Sentry.TelemetryProcessor` and wires it
  into the current test's config scope.

  This is called automatically by `setup_sentry/1` and
  `start_collecting_sentry_reports/0`, so most users do not need to invoke
  it directly. It is exposed for tests that want to perform the setup
  without opening a Bypass.

  The helper:

    * starts a fresh `Sentry.TelemetryProcessor` under the ExUnit test
      supervisor with a unique name,
    * allows the scheduler PID in `Sentry.Test.Config` so that per-test
      config overrides reach it,
    * stores the processor name in the process dictionary under
      `:sentry_telemetry_processor` so that `Sentry.TelemetryProcessor.add/1`
      and friends route to it.

  Returns the processor name (an atom).

  Must be called from within an ExUnit test because it uses
  `ExUnit.Callbacks.start_supervised!/2` for automatic cleanup.

  ## Options

  `tp_opts` is a keyword list forwarded to the per-test
  `Sentry.TelemetryProcessor` child spec (e.g. `buffer_configs`,
  `buffer_capacities`, `scheduler_weights`, `transport_capacity`).

  Idempotency depends on `tp_opts`:

    * with no `tp_opts`, an already-registered live processor (for example
      one started by `Sentry.Case`) is reused and its name returned;
    * with `tp_opts`, an already-registered live processor is stopped and
      restarted under the same name with the given options, so callers no
      longer need to `stop_supervised!/1` + `start_supervised!/2` manually.
  """
  @doc since: "13.0.0"
  @spec setup_telemetry_processor(keyword()) :: atom()
  def setup_telemetry_processor(tp_opts \\ []) do
    case Process.get(:sentry_telemetry_processor) do
      name when is_atom(name) and not is_nil(name) ->
        cond do
          not processor_alive?(name) -> start_telemetry_processor(tp_opts)
          tp_opts == [] -> name
          true -> restart_telemetry_processor(name, tp_opts)
        end

      _ ->
        start_telemetry_processor(tp_opts)
    end
  end

  defp start_telemetry_processor(tp_opts) do
    uid = System.unique_integer([:positive])
    processor_name = :"test_telemetry_processor_#{uid}"

    start_processor_child(processor_name, tp_opts)

    # Must be set before tag_scheduler/1, which reads
    # `:sentry_telemetry_processor` from this process's dictionary via
    # `fetch_owner_processor/1`. Tagging would otherwise be a silent no-op.
    Process.put(:sentry_telemetry_processor, processor_name)

    tag_scheduler(processor_name)
    processor_name
  end

  defp restart_telemetry_processor(name, tp_opts) do
    ExUnit.Callbacks.stop_supervised!(name)
    start_processor_child(name, tp_opts)
    # The process dictionary already holds `name`; the new scheduler pid
    # must be re-tagged since the old one died with the old supervisor.
    tag_scheduler(name)
    name
  end

  defp start_processor_child(name, tp_opts) do
    opts =
      [name: name, processor_resolver: &Sentry.Test.Registry.lookup_processor_for/1]
      |> Keyword.merge(tp_opts)

    ExUnit.Callbacks.start_supervised!({Sentry.TelemetryProcessor, opts}, id: name)
  end

  defp tag_scheduler(processor_name) do
    scheduler_pid = Sentry.TelemetryProcessor.get_scheduler(processor_name)

    if scheduler_pid do
      # Goes through the unified `:sentry_test_scope` key, which also
      # populates the merged routing ETS row so `Config.namespace/1`
      # resolves the scheduler pid back to this test's scope.
      Sentry.Test.Registry.claim_allow(self(), scheduler_pid, :soft)
      tag_processor_for_allowed_pid(self(), scheduler_pid)
    end

    :ok
  end

  defp processor_alive?(name) do
    case Process.whereis(name) do
      pid when is_pid(pid) -> Process.alive?(pid)
      _ -> false
    end
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
      setup_telemetry_processor()
      setup_collector([])
    end

    :ok
  end

  @doc """
  Starts collecting events.

  > #### Deprecated {: .warning}
  >
  > This function is deprecated and will be removed in v14.0.0. Use `setup_sentry/1` instead.

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
  > This function is deprecated and will be removed in v14.0.0.
  > Cleanup is now handled automatically when the owning test process exits.
  """
  @doc since: "10.2.0"
  @doc deprecated: "Cleanup is now automatic when the owning test process exits"
  @spec cleanup(pid()) :: :ok
  def cleanup(owner_pid) when is_pid(owner_pid) do
    :ok
  end

  @doc """
  Allows `pid_to_allow` to collect events back to `owner_pid`'s test scope.

  Use this when an unrelated process — one that does not appear in the
  current test's `$callers` chain — needs to have its captured events
  routed into this test's collector. Typical examples include Broadway
  workers, processes started by `phoenix_test_playwright`, or
  long-lived `GenServer`s that outlive the calling test process.

  `pid_to_allow` may be a pid or a zero-arity function returning a pid;
  the function form is resolved on call and is convenient when the pid
  is not known until later.

  This function is idempotent for the same `owner_pid`. It raises
  `ArgumentError` when `owner_pid` has not yet called `setup_sentry/1`
  (or `start_collecting_sentry_reports/0`), and raises when a different
  live test scope already owns `pid_to_allow`.

  Cleanup is automatic: allow entries are removed when the test exits
  via the same `on_exit` callback registered by `setup_sentry/1`.

  ## Example

      setup do
        Sentry.Test.setup_sentry()
      end

      test "events from a Broadway worker are captured" do
        {:ok, worker_pid} = MyApp.Worker.start_link()
        :ok = Sentry.Test.allow_sentry_reports(self(), worker_pid)

        send(worker_pid, :do_work_that_reports)

        assert_receive {:done, _}
        assert [%Sentry.Event{}] = Sentry.Test.pop_sentry_reports()
      end

  """
  @doc since: "13.0.2"
  @spec allow_sentry_reports(pid(), pid() | (-> pid())) :: :ok
  def allow_sentry_reports(owner_pid, pid_or_fun) when is_pid(owner_pid) do
    allowed_pid = resolve_allowed_pid(pid_or_fun)

    unless owner_collecting?(owner_pid) do
      raise ArgumentError,
            "owner #{inspect(owner_pid)} is not collecting Sentry reports; " <>
              "call Sentry.Test.setup_sentry/1 or " <>
              "Sentry.Test.start_collecting_sentry_reports/0 first"
    end

    # Single orchestrator call: claims `allowed_pid` for `owner_pid` via
    # NimbleOwnership against the unified `:sentry_test_scope` key (which
    # also gates the collector callback) and writes the merged routing
    # row. After it succeeds, tag the per-test processor for buffered
    # event routing — the row is already present so this is a cheap
    # `:ets.update_element/3`.
    case Sentry.Test.Registry.claim_allow(owner_pid, allowed_pid, :strict) do
      :ok ->
        tag_processor_for_allowed_pid(owner_pid, allowed_pid)
        :ok

      {:error, {:taken, ^allowed_pid}} ->
        raise ArgumentError,
              "cannot allow #{inspect(allowed_pid)} for #{inspect(owner_pid)}: " <>
                "#{inspect(allowed_pid)} is already collecting Sentry reports " <>
                "itself (called setup_sentry/1 or start_collecting_sentry_reports/0)"

      {:error, {:taken, existing_owner}} ->
        raise ArgumentError,
              "cannot allow #{inspect(allowed_pid)} for #{inspect(owner_pid)}: " <>
                "already allowed by another live test scope " <>
                "(owner: #{inspect(existing_owner)})"
    end
  end

  defp owner_collecting?(owner_pid) do
    # A scope is "collecting" only when it has a collector table, i.e.
    # `setup_collector/1` ran for it. A lazy scope (config-only test,
    # registered by `Sentry.Test.Registry`) has `collector_table: nil`,
    # so callers get a useful error pointing them at `setup_sentry/1`.
    not is_nil(Sentry.Test.Registry.collector_table_for(owner_pid))
  end

  defp resolve_allowed_pid(pid) when is_pid(pid), do: pid

  defp resolve_allowed_pid(fun) when is_function(fun, 0) do
    case fun.() do
      pid when is_pid(pid) ->
        pid

      other ->
        raise ArgumentError,
              "expected the function passed to allow_sentry_reports/2 to return a pid, " <>
                "got: #{inspect(other)}"
    end
  end

  # Routes buffered events (logs, metrics) emitted from an allowed
  # pid to the owning test's per-test TelemetryProcessor rather than
  # the global one. Without this, the buffered pipeline invokes the
  # test's collecting callback in the global scheduler pid — which
  # is not in the test's NimbleOwnership allow chain — and the
  # callback drops the event.
  #
  # The owner's processor name is looked up from its process
  # dictionary; tests set it in `setup_telemetry_processor/1`. If the
  # owner has no per-test processor (e.g. legacy
  # `start_collecting/1` without `setup_telemetry_processor/1`), the
  # tag is skipped and the buffered event still falls back to the
  # global processor — the same behaviour as before this change.
  defp tag_processor_for_allowed_pid(owner_pid, allowed_pid) do
    case fetch_owner_processor(owner_pid) do
      nil ->
        :ok

      processor_name ->
        Sentry.Test.Registry.tag_processor_for(allowed_pid, processor_name)
    end
  end

  defp fetch_owner_processor(owner_pid) do
    case Process.info(owner_pid, :dictionary) do
      {:dictionary, dict} ->
        case Keyword.get(dict, :sentry_telemetry_processor) do
          name when is_atom(name) and not is_nil(name) -> name
          _ -> nil
        end

      nil ->
        nil
    end
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
  @doc since: "13.0.0"
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
  @doc since: "13.0.0"
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
  @doc since: "13.0.0"
  @spec extract_events([[{map(), map()}]]) :: [map()]
  def extract_events(envelope_items_list) do
    for items <- envelope_items_list,
        {%{"type" => "event"}, payload} <- items,
        do: payload
  end

  @doc """
  Extracts transaction payloads from decoded envelope item lists.
  """
  @doc since: "13.0.0"
  @spec extract_transactions([[{map(), map()}]]) :: [map()]
  def extract_transactions(envelope_items_list) do
    for items <- envelope_items_list,
        {%{"type" => "transaction"}, payload} <- items,
        do: payload
  end

  @doc """
  Extracts log item payloads from decoded envelope item lists.
  """
  @doc since: "13.0.0"
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
  @doc since: "13.0.0"
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

    # Register this test as the NimbleOwnership owner of the scope key,
    # with the canonical collecting metadata (`%{collector_table: table}`)
    # as its value. NimbleOwnership monitors the owner pid and auto-cleans
    # the key + every transitive allowance when the test process exits.
    {:ok, _} =
      NimbleOwnership.get_and_update(
        @ownership_server,
        self(),
        Sentry.Test.Registry.scope_key(),
        fn _prev -> {:ok, Sentry.Test.Registry.collector_metadata(collector_table)} end
      )

    # Store in process dict for pop_* lookups
    Process.put(:sentry_test_collector, collector_table)

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

    config = Keyword.merge([finch_request_opts: [receive_timeout: 2000]], extra_config)

    put_test_config(config)

    # Install standalone collecting callbacks under internal slots. They're
    # composed with the user-provided :before_send / :before_send_log /
    # :before_send_metric in `Sentry.Config` based on DSN value: when DSN is
    # `nil`, only these collecting callbacks run; when DSN is set, the user's
    # callback runs first and its result is collected.
    collector = build_collecting_callback(self())
    Sentry.Test.Config.put_override(:_internal_before_send, collector)
    Sentry.Test.Config.put_override(:_internal_before_send_log, collector)
    Sentry.Test.Config.put_override(:_internal_before_send_metric, collector)

    # The TelemetryProcessor's scheduler is not in `$callers` of this test —
    # allow it explicitly so log/metric events routed through the buffered
    # pipeline can find this test's collector. Routes through the orchestrator
    # so the merged routing row is updated alongside the NimbleOwnership claim.
    scheduler_pid = get_scheduler_pid()

    if scheduler_pid do
      Sentry.Test.Registry.claim_allow(self(), scheduler_pid, :soft)
      tag_processor_for_allowed_pid(self(), scheduler_pid)
    end

    # Register cleanup for the collector ETS table only. NimbleOwnership
    # cleans up the key and allowances automatically when this test exits.
    # Drop any worker→processor routing rows that point at this test's
    # processor so a test that exits before its allowed pids do not
    # leave stale rows pointing at a stopped per-test processor.
    processor_name = Process.get(:sentry_telemetry_processor)

    ExUnit.Callbacks.on_exit(fn ->
      if :ets.whereis(collector_table) != :undefined do
        :ets.delete(collector_table)
      end

      if is_atom(processor_name) and not is_nil(processor_name) do
        Sentry.Test.Registry.drop_processor_routing_for(processor_name)
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

  # Standalone collecting callback. Records the struct in the owning
  # test's collector ETS table, then returns the struct unchanged so it
  # flows through any remaining pipeline stages.
  #
  # The owner pid is captured in the closure at install time so the
  # callback always routes to the test that installed it, regardless of
  # which process invokes it (the test pid, an allowed worker pid, the
  # per-test scheduler pid, or the global TelemetryProcessor scheduler
  # pid).
  #
  # Membership is still enforced via NimbleOwnership: the calling pid
  # (or any of its `$callers`) must be in `owner_pid`'s allow chain for
  # the collector key. This preserves the pre-existing safety check
  # that processes outside the test's allow set never have their
  # events collected.
  defp build_collecting_callback(owner_pid) do
    fn struct ->
      with true <- Process.alive?(owner_pid),
           true <- caller_allowed_for?(owner_pid),
           table when not is_nil(table) <-
             Sentry.Test.Registry.collector_table_for(owner_pid) do
        collect_struct(table, struct)
      end

      struct
    end
  end

  defp caller_allowed_for?(owner_pid) do
    pids = [self() | Process.get(:"$callers", [])]

    case NimbleOwnership.fetch_owner(@ownership_server, pids, Sentry.Test.Registry.scope_key()) do
      {:ok, ^owner_pid} -> true
      _ -> false
    end
  end

  # The collector runs in `before_send`, which executes before
  # `Sentry.Client` calls `maybe_dedupe/1`.
  #
  # This will go away in 14.0.0 along with the full switch to
  # Telemetry Processor and simplified testing infra.
  defp collect_struct(table, %Sentry.Event{} = event) do
    unless Sentry.Config.dedup_events?() and Sentry.Dedupe.member?(event) do
      :ets.insert(table, {System.unique_integer([:monotonic]), event})
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
