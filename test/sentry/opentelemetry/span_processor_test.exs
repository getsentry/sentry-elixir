defmodule Sentry.Opentelemetry.SpanProcessorTest do
  use Sentry.Case, async: false

  import Sentry.TestHelpers

  alias Sentry.OpenTelemetry.SpanStorage

  setup do
    on_exit(fn ->
      # Only try to clean up tables if they exist
      if :ets.whereis(:span_storage) != :undefined do
        :ets.delete_all_objects(:span_storage)
      end
    end)

    :ok
  end

  defmodule TestEndpoint do
    require OpenTelemetry.Tracer, as: Tracer

    def instrumented_function do
      Tracer.with_span "instrumented_function" do
        :timer.sleep(100)

        child_instrumented_function("one")
        child_instrumented_function("two")
      end
    end

    def child_instrumented_function(name) do
      Tracer.with_span "child_instrumented_function_#{name}" do
        :timer.sleep(140)
      end
    end
  end

  test "sends captured root spans as transactions" do
    put_test_config(environment_name: "test")

    Sentry.Test.start_collecting_sentry_reports()

    TestEndpoint.child_instrumented_function("one")

    assert [%Sentry.Transaction{} = transaction] = Sentry.Test.pop_sentry_transactions()

    transaction_data = Sentry.Transaction.to_map(transaction)

    assert transaction_data.event_id
    assert transaction_data.environment == "test"
    assert transaction_data.type == "transaction"
    assert transaction_data.op == "child_instrumented_function_one"
    assert_valid_iso8601(transaction_data.timestamp)
    assert_valid_iso8601(transaction_data.start_timestamp)
    assert transaction_data.timestamp > transaction_data.start_timestamp
    assert_valid_trace_id(transaction_data.contexts.trace.trace_id)
    assert length(transaction_data.spans) == 0
  end

  test "sends captured spans as transactions with child spans" do
    put_test_config(environment_name: "test")

    Sentry.Test.start_collecting_sentry_reports()

    TestEndpoint.instrumented_function()

    assert [%Sentry.Transaction{} = transaction] = Sentry.Test.pop_sentry_transactions()

    transaction_data = Sentry.Transaction.to_map(transaction)

    assert transaction_data.op == "instrumented_function"
    assert_valid_iso8601(transaction_data.timestamp)
    assert_valid_iso8601(transaction_data.start_timestamp)
    assert transaction_data.timestamp > transaction_data.start_timestamp
    assert length(transaction_data.spans) == 2

    [child_span_one, child_span_two] = transaction_data.spans
    assert child_span_one.op == "child_instrumented_function_one"
    assert child_span_two.op == "child_instrumented_function_two"
    assert child_span_one.parent_span_id == transaction.contexts.trace.span_id
    assert child_span_two.parent_span_id == transaction.contexts.trace.span_id

    assert_valid_iso8601(child_span_one.timestamp)
    assert_valid_iso8601(child_span_one.start_timestamp)
    assert_valid_iso8601(child_span_two.timestamp)
    assert_valid_iso8601(child_span_two.start_timestamp)

    assert child_span_one.timestamp > child_span_one.start_timestamp
    assert child_span_two.timestamp > child_span_two.start_timestamp
    assert transaction_data.timestamp >= child_span_one.timestamp
    assert transaction_data.timestamp >= child_span_two.timestamp
    assert transaction_data.start_timestamp <= child_span_one.start_timestamp
    assert transaction_data.start_timestamp <= child_span_two.start_timestamp

    assert_valid_trace_id(transaction.contexts.trace.trace_id)
    assert_valid_trace_id(child_span_one.trace_id)
    assert_valid_trace_id(child_span_two.trace_id)
  end

  test "removes span records from storage after sending a transaction" do
    put_test_config(environment_name: "test")

    Sentry.Test.start_collecting_sentry_reports()

    TestEndpoint.instrumented_function()

    assert [%Sentry.Transaction{} = transaction] = Sentry.Test.pop_sentry_transactions()

    assert nil == SpanStorage.get_root_span(transaction.contexts.trace.span_id)
    assert [] == SpanStorage.get_child_spans(transaction.contexts.trace.span_id)
  end

  defp assert_valid_iso8601(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, datetime, _offset} ->
        assert datetime.year >= 2023, "Expected year to be 2023 or later, got: #{datetime.year}"
        assert is_binary(timestamp), "Expected timestamp to be a string"
        assert String.ends_with?(timestamp, "Z"), "Expected timestamp to end with 'Z'"

      {:error, reason} ->
        flunk("Invalid ISO8601 timestamp: #{timestamp}, reason: #{inspect(reason)}")
    end
  end

  defp assert_valid_trace_id(trace_id) do
    assert is_binary(trace_id), "Expected trace_id to be a string"
    assert String.length(trace_id) == 32, "Expected trace_id to be 32 characters long #{trace_id}"

    assert String.match?(trace_id, ~r/^[a-f0-9]{32}$/),
           "Expected trace_id to be a lowercase hex string"
  end
end
