defmodule Sentry.Opentelemetry.SamplerTest do
  use Sentry.Case, async: true

  alias Sentry.OpenTelemetry.Sampler
  alias Sentry.ClientReport

  defp create_test_span_context(span_id \\ 123_456_789) do
    {
      :span_ctx,
      12_345_678_901_234_567_890_123_456_789_012,
      span_id,
      1,
      [],
      true,
      false,
      true,
      nil
    }
  end

  setup do
    original_rate = Sentry.Config.traces_sample_rate()

    on_exit(fn ->
      Sentry.Config.put_config(:traces_sample_rate, original_rate)
    end)

    :ok
  end

  describe "span name dropping" do
    test "drops spans with the given name and records discarded event" do
      :sys.replace_state(ClientReport.Sender, fn _ -> %{} end)

      test_ctx = create_test_span_context()

      assert {:drop, [], []} =
               Sampler.should_sample(test_ctx, nil, nil, "Elixir.Oban.Stager process", nil, nil,
                 drop: ["Elixir.Oban.Stager process"]
               )

      Process.sleep(10)

      state = :sys.get_state(ClientReport.Sender)
      assert state == %{{:sample_rate, "transaction"} => 1}
    end

    test "records and samples spans not in drop list" do
      Sentry.Config.put_config(:traces_sample_rate, 1.0)

      test_ctx = create_test_span_context()

      assert {:record_and_sample, [], tracestate} =
               Sampler.should_sample(test_ctx, 123, nil, "Elixir.Oban.Worker process", nil, nil,
                 drop: []
               )

      assert is_list(tracestate)
      assert {"sentry-sample_rate", "1.0"} in tracestate
      assert {"sentry-sampled", "true"} in tracestate
    end
  end

  describe "sampling based on traces_sample_rate" do
    test "always drops when sample rate is 0.0 and records discarded event" do
      :sys.replace_state(ClientReport.Sender, fn _ -> %{} end)

      Sentry.Config.put_config(:traces_sample_rate, 0.0)

      test_ctx = create_test_span_context()

      assert {:drop, [], tracestate} =
               Sampler.should_sample(test_ctx, 123, nil, "test span", nil, nil, drop: [])

      assert {"sentry-sample_rate", "0.0"} in tracestate
      assert {"sentry-sampled", "false"} in tracestate

      Process.sleep(10)

      state = :sys.get_state(ClientReport.Sender)
      assert state == %{{:sample_rate, "transaction"} => 1}
    end

    test "always samples when sample rate is 1.0" do
      Sentry.Config.put_config(:traces_sample_rate, 1.0)

      test_ctx = create_test_span_context()

      assert {:record_and_sample, [], tracestate} =
               Sampler.should_sample(test_ctx, 123, nil, "test span", nil, nil, drop: [])

      assert {"sentry-sample_rate", "1.0"} in tracestate
      assert {"sentry-sampled", "true"} in tracestate
    end

    test "different trace_ids produce different sampling decisions" do
      Sentry.Config.put_config(:traces_sample_rate, 0.5)

      trace_ids = Enum.to_list(1..100)

      results =
        Enum.map(trace_ids, fn trace_id ->
          test_ctx = create_test_span_context()

          {decision, [], _tracestate} =
            Sampler.should_sample(test_ctx, trace_id, nil, "test span", nil, nil, drop: [])

          decision == :record_and_sample
        end)

      sampled_count = Enum.count(results, & &1)

      assert sampled_count > 30 and sampled_count < 70
    end

    test "records discarded events when randomly dropped by sample rate" do
      :sys.replace_state(ClientReport.Sender, fn _ -> %{} end)

      Sentry.Config.put_config(:traces_sample_rate, 0.001)

      Enum.each(1..50, fn trace_id ->
        test_ctx = create_test_span_context()
        Sampler.should_sample(test_ctx, trace_id, nil, "test span", nil, nil, drop: [])
      end)

      Process.sleep(10)

      state = :sys.get_state(ClientReport.Sender)
      discarded_count = Map.get(state, {:sample_rate, "transaction"}, 0)
      assert discarded_count > 0, "Expected some spans to be dropped and recorded"
    end
  end

  describe "parent span inheritance" do
    test "inherits sampling decision from parent span with same trace_id" do
      Sentry.Config.put_config(:traces_sample_rate, 1.0)

      test_ctx = create_test_span_context()

      assert {:record_and_sample, [], _tracestate} =
               Sampler.should_sample(test_ctx, 123, nil, "test span", nil, nil, drop: [])
    end
  end

  describe "tracestate management" do
    test "builds tracestate with correct format" do
      Sentry.Config.put_config(:traces_sample_rate, 0.75)

      test_ctx = create_test_span_context()

      {_decision, [], tracestate} =
        Sampler.should_sample(test_ctx, 123, nil, "test span", nil, nil, drop: [])

      assert List.keyfind(tracestate, "sentry-sample_rate", 0)
      assert List.keyfind(tracestate, "sentry-sample_rand", 0)
      assert List.keyfind(tracestate, "sentry-sampled", 0)

      {"sentry-sample_rate", rate_str} = List.keyfind(tracestate, "sentry-sample_rate", 0)
      assert rate_str == "0.75"

      {"sentry-sampled", sampled_str} = List.keyfind(tracestate, "sentry-sampled", 0)
      assert sampled_str in ["true", "false"]
    end
  end
end
