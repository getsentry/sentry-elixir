defmodule Sentry.Test.Assertions do
  @moduledoc """
  ExUnit assertion helpers for testing Sentry reports.

  These helpers work with data collected by `Sentry.Test` and reduce
  boilerplate when asserting on captured events, transactions, and logs.

  ## Usage

      import Sentry.Test.Assertions

  ## Examples

  Assert that exactly one event was captured with specific fields:

      assert_sentry_report(:event, level: :error, message: %{formatted: "hello"})

  Assert a transaction:

      assert_sentry_report(:transaction, transaction: "my_span")

  Use the log shorthand:

      assert_sentry_log(:info, "User session started")
      assert_sentry_log(:info, ~r/session started/, trace_id: "abc123")

  Find a specific event among many:

      events = Sentry.Test.pop_sentry_reports()
      event = find_sentry_report!(events, message: %{formatted: ~r/hello/})

  ## Awaiting Asynchronous Reports

  Log and metric events flow through the `Sentry.TelemetryProcessor` pipeline
  asynchronously. The type-form of `assert_sentry_report/2` and
  `assert_sentry_log/3` await internally — they flush the telemetry pipeline
  and poll the collector with exponential backoff until at least one matching
  item is captured, up to a timeout (default `#{1000}ms`).

  Tests typically do not need to call `Sentry.TelemetryProcessor.flush/0`
  or `Process.sleep/1` before these assertions.

  Override the default via the reserved `:timeout` keyword:

      assert_sentry_report(:log, [level: :info, body: "hi"], timeout: 2000)
      assert_sentry_log(:info, "hi", timeout: 2000)

  """
  @moduledoc since: "12.1.0"

  import ExUnit.Assertions, only: [flunk: 1]

  @default_timeout 1000
  @max_poll_interval 50

  @type_to_pop %{
    event: &Sentry.Test.pop_sentry_reports/0,
    transaction: &Sentry.Test.pop_sentry_transactions/0,
    log: &Sentry.Test.pop_sentry_logs/0,
    metric: &Sentry.Test.pop_sentry_metrics/0
  }

  @doc """
  Asserts that a report matches the given criteria.

  This function has two forms:

  ## Auto-pop by type

  When the first argument is a type atom (`:event`, `:transaction`, or `:log`),
  it pops collected items internally — no need to call `pop_sentry_reports/0`
  yourself. Asserts that exactly one item was captured and validates it.

    * `:event` — pops from `Sentry.Test.pop_sentry_reports/0`
    * `:transaction` — pops from `Sentry.Test.pop_sentry_transactions/0`
    * `:log` — pops from `Sentry.Test.pop_sentry_logs/0`

  ## Explicit data

  When the first argument is a map or single-element list, it validates the
  item against the criteria directly. Use this with data from envelope
  collection helpers.

  ## Criteria

  Each key-value pair in `criteria` is checked against the item:

    * **Regex** — matches with `=~/2`
    * **Plain map** (not a struct) — recursive subset match: every key
      in the expected map must exist in the actual value with a matching value
    * **Any other value** — compared with `==/2`

  Atom keys are resolved with a string-key fallback, so atom-key criteria
  also work on decoded JSON maps.

  Returns the matched item for further assertions.

  ## Examples

      event = assert_sentry_report(:event,
        level: :error,
        source: :plug,
        message: %{formatted: "hello"}
      )

      assert_sentry_report(:transaction, transaction: "test_span")

      # With explicit data from envelope collection:
      [event] = collect_sentry_events(ref, 1)
      assert_sentry_report(event, "tags" => %{"oban_queue" => "default"})

  """
  @doc since: "12.1.0"
  def assert_sentry_report(type_or_item, criteria)

  @spec assert_sentry_report(:event | :transaction | :log | :metric, keyword()) ::
          Sentry.Event.t() | Sentry.Transaction.t() | Sentry.LogEvent.t() | Sentry.Metric.t()
  def assert_sentry_report(type, criteria) when type in [:event, :transaction, :log, :metric] do
    {timeout, criteria} = Keyword.pop(criteria, :timeout, @default_timeout)
    label = type_label(type)

    items = await_items(type, timeout, &(length(&1) >= 1))
    item = unwrap_single!(items, label, timeout)
    assert_fields!(item, criteria, label)
    item
  end

  @spec assert_sentry_report(map() | [map()], keyword() | [{binary(), term()}]) :: map()
  def assert_sentry_report(item_or_list, criteria)
      when (is_map(item_or_list) or is_list(item_or_list)) and
             (is_list(criteria) or is_map(criteria)) do
    item = unwrap_single!(item_or_list, "report")
    assert_fields!(item, criteria, "report")
    item
  end

  @doc """
  Asserts that a log was captured matching the given level and body pattern.

  Awaits asynchronously-captured logs: the pipeline is flushed and the
  collector is polled until a log matching the criteria is found or the
  timeout elapses (default `#{1000}ms`, overridable via the `:timeout`
  reserved key in `extra_criteria`).

  Once at least one candidate log is available, finds the first one matching
  `level` and `body_pattern`. This uses find semantics (not assert-exactly-1)
  because logs often come in batches.

  The optional third argument is a keyword list of extra criteria to match
  on any `Sentry.LogEvent` field, plus the reserved `:timeout` option.

  Returns the matched log event.

  ## Examples

      assert_sentry_log(:info, "User session started")
      assert_sentry_log(:error, ~r/connection refused/)
      assert_sentry_log(:info, "User session started", trace_id: "abc123")
      assert_sentry_log(:info, "User session started", attributes: %{id: 312})
      assert_sentry_log(:info, "slow path", timeout: 2000)

  """
  @doc since: "12.1.0"
  @spec assert_sentry_log(Sentry.LogEvent.level(), String.t() | Regex.t(), keyword()) ::
          Sentry.LogEvent.t()
  def assert_sentry_log(level, body_pattern, extra_criteria \\ [])
      when is_atom(level) and (is_binary(body_pattern) or is_struct(body_pattern, Regex)) do
    {timeout, extra_criteria} = Keyword.pop(extra_criteria, :timeout, @default_timeout)
    criteria = [level: level, body: body_pattern] ++ extra_criteria

    logs =
      await_items(:log, timeout, fn items ->
        Enum.any?(items, &matches_criteria?(&1, criteria))
      end)

    find_item!(logs, criteria, "log")
  end

  @doc """
  Finds the first item in `items` that matches all `criteria`.

  Raises with a descriptive error if no match is found. Works with both
  structs (atom keys) and decoded JSON maps (string keys).

  ## Examples

      events = Sentry.Test.pop_sentry_reports()
      event = find_sentry_report!(events, message: %{formatted: ~r/hello/})

  """
  @doc since: "12.1.0"
  @spec find_sentry_report!([map()], keyword() | [{binary(), term()}]) :: map()
  def find_sentry_report!(items, criteria) when is_list(items) do
    find_item!(items, criteria, "report")
  end

  # --- Private helpers ---

  defp pop_for_type(type) do
    Map.fetch!(@type_to_pop, type).()
  end

  defp await_items(type, timeout, done_fn) do
    maybe_flush(timeout)
    deadline = System.monotonic_time(:millisecond) + timeout
    await_loop(type, deadline, 1, [], done_fn)
  end

  defp await_loop(type, deadline, sleep_ms, acc, done_fn) do
    acc = acc ++ pop_for_type(type)

    cond do
      done_fn.(acc) ->
        acc

      System.monotonic_time(:millisecond) >= deadline ->
        acc

      true ->
        Process.sleep(sleep_ms)
        await_loop(type, deadline, min(sleep_ms * 2, @max_poll_interval), acc, done_fn)
    end
  end

  # Drains the TelemetryProcessor pipeline synchronously. No-op when no
  # per-test processor is registered (e.g., tests that bypass the pipeline
  # by inserting directly into the collector ETS table).
  defp maybe_flush(timeout) do
    case Process.get(:sentry_telemetry_processor) do
      nil ->
        :ok

      processor ->
        scheduler = Sentry.TelemetryProcessor.scheduler_name(processor)

        if Process.whereis(scheduler) do
          try do
            Sentry.TelemetryProcessor.flush(processor, timeout)
          catch
            :exit, _ -> :ok
          end
        end

        :ok
    end
  end

  defp matches_criteria?(item, criteria) do
    Enum.all?(criteria, fn {key, expected} ->
      match_value?(get_field(item, key), expected)
    end)
  end

  defp type_label(:event), do: "event"
  defp type_label(:transaction), do: "transaction"
  defp type_label(:log), do: "log"
  defp type_label(:metric), do: "metric"

  defp unwrap_single!(items_or_item, label, timeout \\ nil)

  defp unwrap_single!([single], _label, _timeout), do: single
  defp unwrap_single!(item, _label, _timeout) when is_map(item), do: item

  defp unwrap_single!([], label, nil) do
    flunk("""
    Expected exactly 1 Sentry #{label}, got 0.

    Make sure setup_sentry/1 was called and the event was sent with result: :sync.\
    """)
  end

  defp unwrap_single!([], label, timeout) do
    flunk("""
    Expected 1 Sentry #{label} within #{timeout}ms, got 0.

    Ensure the TelemetryProcessor is running for this test (via Sentry.Case or
    Sentry.Test.setup_sentry/1) and that the event was emitted before the
    assertion. For slow pipelines, pass a larger `:timeout` option.\
    """)
  end

  defp unwrap_single!(list, label, _timeout) when is_list(list) do
    flunk("""
    Expected exactly 1 Sentry #{label}, got #{length(list)}.

    Use find_sentry_report!/2 to search within multiple items.\
    """)
  end

  defp assert_fields!(item, criteria, label) do
    mismatches =
      Enum.reduce(criteria, [], fn {key, expected}, acc ->
        actual = get_field(item, key)

        if match_value?(actual, expected) do
          acc
        else
          [{key, expected, actual} | acc]
        end
      end)

    unless mismatches == [] do
      flunk(format_mismatch_error(Enum.reverse(mismatches), label))
    end
  end

  defp find_item!(items, criteria, label) do
    Enum.find(items, &matches_criteria?(&1, criteria)) ||
      flunk(format_find_error(items, criteria, label))
  end

  defp get_field(data, key) when is_atom(key) do
    case Map.fetch(data, key) do
      {:ok, value} -> value
      :error -> Map.get(data, to_string(key))
    end
  end

  defp get_field(data, key) when is_binary(key) do
    case Map.fetch(data, key) do
      {:ok, value} ->
        value

      :error ->
        try do
          Map.get(data, String.to_existing_atom(key))
        rescue
          ArgumentError -> nil
        end
    end
  end

  defp match_value?(actual, %Regex{} = expected) do
    is_binary(actual) and actual =~ expected
  end

  defp match_value?(actual, expected) when is_map(expected) and not is_struct(expected) do
    is_map(actual) and
      Enum.all?(expected, fn {k, v} ->
        match_value?(get_field(actual, k), v)
      end)
  end

  defp match_value?(actual, expected) do
    actual == expected
  end

  defp format_mismatch_error(mismatches, label) do
    fields =
      Enum.map_join(mismatches, "\n\n", fn {key, expected, actual} ->
        """
          #{inspect(key)}
            expected: #{inspect(expected, limit: 5, printable_limit: 100)}
            got:      #{inspect(actual, limit: 5, printable_limit: 100)}\
        """
      end)

    "Sentry #{label} assertion failed:\n\n#{fields}"
  end

  defp format_find_error(items, criteria, label) do
    """
    No matching Sentry #{label} found in #{length(items)} item(s).

    Criteria: #{inspect(criteria, limit: 10, printable_limit: 200)}\
    """
  end
end
