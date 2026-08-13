defmodule Sentry.Opentelemetry.DistributedTracesTest do
  # Asserts only on reported envelopes, never on span-processing internals,
  # so this coverage holds across changes to how spans are processed.

  use Sentry.Case, async: false

  require OpenTelemetry.Tracer, as: Tracer

  import Sentry.TestHelpers

  @trace_id String.duplicate("a", 32)
  @remote_span_id String.duplicate("b", 16)

  setup do
    setup_bypass()
  end

  describe "a trace continued from an upstream service" do
    test "is reported even when its local root is not a server span", %{bypass: bypass} do
      put_test_config(environment_name: "test", traces_sample_rate: 1.0)
      ref = setup_bypass_envelope_collector(bypass)

      continue_remote_trace()

      Tracer.with_span "job.run" do
        Tracer.with_span "job.step" do
          Process.sleep(1)
        end
      end

      assert [tx] = collect_sentry_transactions(ref, 1, timeout: 1000),
             "nothing was reported for a non-server span under a remote parent"

      assert tx["transaction"] == "job.run"

      trace = tx["contexts"]["trace"]
      assert trace["trace_id"] == @trace_id
      assert trace["parent_span_id"] == @remote_span_id

      assert [step] = tx["spans"]
      assert step["description"] == "job.step"
      assert step["parent_span_id"] == trace["span_id"]
      assert step["trace_id"] == @trace_id
    end

    test "is reported as a single transaction, not one per span", %{bypass: bypass} do
      put_test_config(environment_name: "test", traces_sample_rate: 1.0)
      ref = setup_bypass_envelope_collector(bypass)

      continue_remote_trace()

      Tracer.with_span "job.run" do
        Tracer.with_span "job.step" do
          Tracer.with_span "job.substep" do
            Process.sleep(1)
          end
        end
      end

      transactions = collect_sentry_transactions(ref, 5, timeout: 1000)

      assert length(transactions) == 1,
             "expected one transaction for the whole trace, got: " <>
               inspect(Enum.map(transactions, & &1["transaction"]))

      [tx] = transactions
      assert tx["transaction"] == "job.run"

      span_descriptions = tx["spans"] |> Enum.map(& &1["description"]) |> Enum.sort()
      assert span_descriptions == ["job.step", "job.substep"]
    end
  end

  defp continue_remote_trace do
    :otel_propagator_text_map.extract([
      {"traceparent", "00-#{@trace_id}-#{@remote_span_id}-01"}
    ])

    :ok
  end
end
