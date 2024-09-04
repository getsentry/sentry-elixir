defmodule Sentry.Telemetry.SpanProcessorTest do
  use Sentry.Case, async: false

  import Sentry.TestHelpers

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

    assert_valid_iso8601(transaction.timestamp)
    assert_valid_iso8601(transaction.start_timestamp)
    assert transaction.timestamp > transaction.start_timestamp
    assert length(transaction.spans) == 1

    assert_valid_trace_id(transaction.contexts.trace.trace_id)

    assert [span] = transaction.spans

    assert span.op == "child_instrumented_function_one"
  end

  test "sends captured spans as transactions with child spans" do
    put_test_config(environment_name: "test")

    Sentry.Test.start_collecting_sentry_reports()

    TestEndpoint.instrumented_function()

    assert [%Sentry.Transaction{} = transaction] = Sentry.Test.pop_sentry_transactions()

    assert_valid_iso8601(transaction.timestamp)
    assert_valid_iso8601(transaction.start_timestamp)
    assert transaction.timestamp > transaction.start_timestamp
    assert length(transaction.spans) == 3

    [root_span, child_span_one, child_span_two] = transaction.spans
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
    assert root_span.timestamp >= child_span_one.timestamp
    assert root_span.timestamp >= child_span_two.timestamp
    assert root_span.start_timestamp <= child_span_one.start_timestamp
    assert root_span.start_timestamp <= child_span_two.start_timestamp

    assert_valid_trace_id(transaction.contexts.trace.trace_id)
    assert_valid_trace_id(child_span_one.trace_id)
    assert_valid_trace_id(child_span_two.trace_id)
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
