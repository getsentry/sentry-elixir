defmodule Sentry.MetricBatchTest do
  use Sentry.Case, async: true

  alias Sentry.{Metric, MetricBatch}

  describe "struct" do
    test "creates a metric batch with a list of metrics" do
      metrics = [
        %Metric{
          type: :counter,
          name: "test.counter",
          value: 1,
          timestamp: 1_588_601_261.535_386
        },
        %Metric{
          type: :gauge,
          name: "test.gauge",
          value: 42.5,
          timestamp: 1_588_601_261.544_196
        }
      ]

      metric_batch = %MetricBatch{metrics: metrics}

      assert metric_batch.metrics == metrics
      assert length(metric_batch.metrics) == 2
    end

    test "enforces required :metrics key" do
      assert_raise ArgumentError, ~r/the following keys must also be given/, fn ->
        struct!(MetricBatch, %{})
      end
    end
  end
end
