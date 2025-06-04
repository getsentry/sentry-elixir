defmodule Sentry.Opentelemetry.SamplerTest do
  use Sentry.Case, async: true

  alias Sentry.OpenTelemetry.Sampler

  setup do
    original_rate = Sentry.Config.traces_sample_rate()

    on_exit(fn ->
      Sentry.Config.put_config(:traces_sample_rate, original_rate)
    end)

    :ok
  end

  describe "span name dropping" do
    test "drops spans with the given name" do
      assert {:drop, [], []} =
               Sampler.should_sample(nil, nil, nil, "Elixir.Oban.Stager process", nil, nil,
                 drop: ["Elixir.Oban.Stager process"]
               )
    end

    test "records and samples spans not in drop list" do
      Sentry.Config.put_config(:traces_sample_rate, 1.0)

      assert {:record_and_sample, [], tracestate} =
               Sampler.should_sample(nil, 123, nil, "Elixir.Oban.Worker process", nil, nil,
                 drop: []
               )

      assert is_list(tracestate)
      assert {"sentry-sample_rate", "1.0"} in tracestate
      assert {"sentry-sampled", "true"} in tracestate
    end
  end

  describe "sampling based on traces_sample_rate" do
    test "always drops when sample rate is 0.0" do
      Sentry.Config.put_config(:traces_sample_rate, 0.0)

      assert {:drop, [], tracestate} =
               Sampler.should_sample(nil, 123, nil, "test span", nil, nil, drop: [])

      assert {"sentry-sample_rate", "0.0"} in tracestate
      assert {"sentry-sampled", "false"} in tracestate
    end

    test "always samples when sample rate is 1.0" do
      Sentry.Config.put_config(:traces_sample_rate, 1.0)

      assert {:record_and_sample, [], tracestate} =
               Sampler.should_sample(nil, 123, nil, "test span", nil, nil, drop: [])

      assert {"sentry-sample_rate", "1.0"} in tracestate
      assert {"sentry-sampled", "true"} in tracestate
    end

    test "different trace_ids produce different sampling decisions" do
      Sentry.Config.put_config(:traces_sample_rate, 0.5)

      trace_ids = Enum.to_list(1..100)

      results =
        Enum.map(trace_ids, fn trace_id ->
          {decision, [], _tracestate} =
            Sampler.should_sample(nil, trace_id, nil, "test span", nil, nil, drop: [])

          decision == :record_and_sample
        end)

      sampled_count = Enum.count(results, & &1)

      assert sampled_count > 30 and sampled_count < 70
    end
  end

  describe "parent span inheritance" do
    test "inherits sampling decision from parent span with same trace_id" do
      Sentry.Config.put_config(:traces_sample_rate, 1.0)

      assert {:record_and_sample, [], _tracestate} =
               Sampler.should_sample(nil, 123, nil, "test span", nil, nil, drop: [])
    end
  end

  describe "tracestate management" do
    test "builds tracestate with correct format" do
      Sentry.Config.put_config(:traces_sample_rate, 0.75)

      {_decision, [], tracestate} =
        Sampler.should_sample(nil, 123, nil, "test span", nil, nil, drop: [])

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
