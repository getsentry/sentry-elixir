defmodule Sentry.Opentelemetry.SpanProcessorTest do
  use Sentry.Case, async: false

  import Sentry.TestHelpers

  alias Sentry.OpenTelemetry.SpanStorage

  defmodule TestEndpoint do
    require OpenTelemetry.Tracer, as: Tracer

    def instrumented_function do
      Tracer.with_span "instrumented_function" do
        Process.sleep(100)

        child_instrumented_function("one")
        child_instrumented_function("two")
      end
    end

    def child_instrumented_function(name) do
      Tracer.with_span "child_instrumented_function_#{name}" do
        Process.sleep(140)
      end
    end
  end

  setup do
    original_rate = Sentry.Config.traces_sample_rate()

    on_exit(fn ->
      Sentry.Config.put_config(:traces_sample_rate, original_rate)
    end)

    :ok
  end

  @tag span_storage: true
  test "sends captured root spans as transactions" do
    put_test_config(environment_name: "test", traces_sample_rate: 1.0)

    Sentry.Test.start_collecting_sentry_reports()

    TestEndpoint.child_instrumented_function("one")

    assert [%Sentry.Transaction{} = transaction] = Sentry.Test.pop_sentry_transactions()

    assert transaction.event_id
    assert transaction.environment == "test"
    assert transaction.transaction_info == %{source: :custom}
    assert_valid_iso8601(transaction.timestamp)
    assert_valid_iso8601(transaction.start_timestamp)
    assert transaction.timestamp > transaction.start_timestamp
    assert_valid_trace_id(transaction.contexts.trace.trace_id)
    assert length(transaction.spans) == 0
  end

  @tag span_storage: true
  test "sends captured spans as transactions with child spans" do
    put_test_config(environment_name: "test", traces_sample_rate: 1.0)

    Sentry.Test.start_collecting_sentry_reports()

    TestEndpoint.instrumented_function()

    assert [%Sentry.Transaction{} = transaction] = Sentry.Test.pop_sentry_transactions()

    assert_valid_iso8601(transaction.timestamp)
    assert_valid_iso8601(transaction.start_timestamp)
    assert transaction.timestamp > transaction.start_timestamp
    assert length(transaction.spans) == 2

    [child_span_one, child_span_two] = transaction.spans
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
    assert transaction.timestamp >= child_span_one.timestamp
    assert transaction.timestamp >= child_span_two.timestamp
    assert transaction.start_timestamp <= child_span_one.start_timestamp
    assert transaction.start_timestamp <= child_span_two.start_timestamp

    assert_valid_trace_id(transaction.contexts.trace.trace_id)
    assert_valid_trace_id(child_span_one.trace_id)
    assert_valid_trace_id(child_span_two.trace_id)
  end

  @tag span_storage: true
  test "removes span records from storage after sending a transaction", %{table_name: table_name} do
    put_test_config(environment_name: "test", traces_sample_rate: 1.0)

    Sentry.Test.start_collecting_sentry_reports()

    TestEndpoint.instrumented_function()

    assert [%Sentry.Transaction{} = transaction] = Sentry.Test.pop_sentry_transactions()

    assert SpanStorage.get_root_span(transaction.contexts.trace.span_id, table_name: table_name) ==
             nil

    assert [] ==
             SpanStorage.get_child_spans(transaction.contexts.trace.span_id,
               table_name: table_name
             )
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
    assert byte_size(trace_id) == 32, "Expected trace_id to be 32 characters long #{trace_id}"

    assert String.match?(trace_id, ~r/^[a-f0-9]{32}$/),
           "Expected trace_id to be a lowercase hex string"
  end

  describe "sampling behavior with root and child spans" do
    @tag span_storage: true
    test "drops entire trace when root span is not sampled" do
      put_test_config(environment_name: "test", traces_sample_rate: 0.0)

      original_sampler = Application.get_env(:opentelemetry, :sampler)
      Application.put_env(:opentelemetry, :sampler, {Sentry.OpenTelemetry.Sampler, [drop: []]})

      Sentry.Test.start_collecting_sentry_reports()

      Enum.each(1..5, fn _ ->
        TestEndpoint.instrumented_function()
      end)

      assert [] = Sentry.Test.pop_sentry_transactions()

      Application.put_env(:opentelemetry, :sampler, original_sampler)
    end

    @tag span_storage: true
    test "samples entire trace when root span is sampled" do
      put_test_config(environment_name: "test", traces_sample_rate: 1.0)

      Sentry.Test.start_collecting_sentry_reports()

      TestEndpoint.instrumented_function()

      assert [%Sentry.Transaction{} = transaction] = Sentry.Test.pop_sentry_transactions()
      assert length(transaction.spans) == 2

      [child_span_one, child_span_two] = transaction.spans
      assert transaction.contexts.trace.trace_id == child_span_one.trace_id
      assert transaction.contexts.trace.trace_id == child_span_two.trace_id
    end

    @tag span_storage: true
    test "child spans inherit parent sampling decision" do
      put_test_config(environment_name: "test", traces_sample_rate: 0.5)

      original_sampler = Application.get_env(:opentelemetry, :sampler)
      Application.put_env(:opentelemetry, :sampler, {Sentry.OpenTelemetry.Sampler, [drop: []]})

      Sentry.Test.start_collecting_sentry_reports()

      Enum.each(1..10, fn _ ->
        TestEndpoint.instrumented_function()
      end)

      transactions = Sentry.Test.pop_sentry_transactions()

      Enum.each(transactions, fn transaction ->
        assert length(transaction.spans) == 2

        [child_span_one, child_span_two] = transaction.spans
        assert transaction.contexts.trace.trace_id == child_span_one.trace_id
        assert transaction.contexts.trace.trace_id == child_span_two.trace_id
      end)

      Application.put_env(:opentelemetry, :sampler, original_sampler)
    end

    @tag span_storage: true
    test "nested child spans maintain sampling consistency" do
      put_test_config(environment_name: "test", traces_sample_rate: 1.0)

      Sentry.Test.start_collecting_sentry_reports()

      require OpenTelemetry.Tracer, as: Tracer

      Tracer.with_span "root_span" do
        Tracer.with_span "level_1_child" do
          Tracer.with_span "level_2_child" do
            Process.sleep(10)
          end

          Tracer.with_span "level_2_sibling" do
            Process.sleep(10)
          end
        end

        Tracer.with_span "level_1_sibling" do
          Process.sleep(10)
        end
      end

      assert [%Sentry.Transaction{} = transaction] = Sentry.Test.pop_sentry_transactions()

      assert length(transaction.spans) == 2

      trace_id = transaction.contexts.trace.trace_id

      Enum.each(transaction.spans, fn span ->
        assert span.trace_id == trace_id
      end)

      span_names = Enum.map(transaction.spans, & &1.op) |> Enum.sort()
      expected_names = ["level_1_child", "level_1_sibling"]
      assert span_names == expected_names
    end

    @tag span_storage: true
    test "child-only spans without root are handled correctly" do
      put_test_config(environment_name: "test", traces_sample_rate: 1.0)

      Sentry.Test.start_collecting_sentry_reports()

      TestEndpoint.child_instrumented_function("standalone")

      assert [%Sentry.Transaction{} = transaction] = Sentry.Test.pop_sentry_transactions()

      assert length(transaction.spans) == 0
      assert transaction.transaction == "child_instrumented_function_standalone"
    end

    @tag span_storage: true
    test "concurrent traces maintain independent sampling decisions" do
      put_test_config(environment_name: "test", traces_sample_rate: 0.5)

      original_sampler = Application.get_env(:opentelemetry, :sampler)
      Application.put_env(:opentelemetry, :sampler, {Sentry.OpenTelemetry.Sampler, [drop: []]})

      Sentry.Test.start_collecting_sentry_reports()

      tasks =
        Enum.map(1..20, fn i ->
          Task.async(fn ->
            require OpenTelemetry.Tracer, as: Tracer

            Tracer.with_span "concurrent_root_#{i}" do
              Tracer.with_span "concurrent_child_#{i}" do
                Process.sleep(10)
              end
            end
          end)
        end)

      Enum.each(tasks, &Task.await/1)

      transactions = Sentry.Test.pop_sentry_transactions()

      Enum.each(transactions, fn transaction ->
        assert length(transaction.spans) == 1
        [child_span] = transaction.spans
        assert child_span.trace_id == transaction.contexts.trace.trace_id
      end)

      assert length(transactions) >= 5
      assert length(transactions) <= 20

      Application.put_env(:opentelemetry, :sampler, original_sampler)
    end

    @tag span_storage: true
    test "span processor respects sampler drop configuration" do
      put_test_config(environment_name: "test", traces_sample_rate: 1.0)

      original_sampler = Application.get_env(:opentelemetry, :sampler)

      Application.put_env(
        :opentelemetry,
        :sampler,
        {Sentry.OpenTelemetry.Sampler, [drop: ["child_instrumented_function_one"]]}
      )

      Sentry.Test.start_collecting_sentry_reports()

      require OpenTelemetry.Tracer, as: Tracer

      Tracer.with_span "root_span" do
        Tracer.with_span "child_instrumented_function_one" do
          Process.sleep(10)
        end

        Tracer.with_span "allowed_child" do
          Process.sleep(10)
        end
      end

      transactions = Sentry.Test.pop_sentry_transactions()

      Enum.each(transactions, fn transaction ->
        trace_id = transaction.contexts.trace.trace_id

        Enum.each(transaction.spans, fn span ->
          assert span.trace_id == trace_id
        end)
      end)

      Application.put_env(:opentelemetry, :sampler, original_sampler)
    end
  end
end
