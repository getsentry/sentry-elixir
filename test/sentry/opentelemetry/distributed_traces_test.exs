defmodule Sentry.Opentelemetry.DistributedTracesTest do
  # Asserts only on reported envelopes, never on span-processing internals,
  # so this coverage holds across changes to how spans are processed.

  use Sentry.Case, async: false

  @moduletag send_result: :none

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

      refute Map.has_key?(trace["data"], "sentry.parent_is_remote")
      refute Enum.any?(tx["spans"], &Map.has_key?(&1["data"], "sentry.parent_is_remote"))
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

  describe "the dynamic sampling context of a continued trace" do
    test "is the one the trace arrived with, as is", %{bypass: bypass} do
      put_test_config(environment_name: "test", traces_sample_rate: 1.0, release: "local-1")
      ref = setup_bypass_envelope_collector(bypass, type: "transaction")

      continue_sentry_trace(
        "sentry-trace_id=#{@trace_id},sentry-public_key=upstream," <>
          "sentry-sample_rate = 0.25,\tsentry-sample_rand\t=0.1 , sentry-sampled=true," <>
          "sentry-release=upstream-7,sentry-environment=prod," <>
          "sentry-transaction=GET%20%2Fupstream;prop=1,other-vendor=x"
      )

      Tracer.with_span "job.run" do
        Tracer.with_span "job.step" do
          Process.sleep(1)
        end
      end

      assert [{trace, _tx}] = collect_transaction_envelopes(ref, 1)

      assert trace == %{
               "trace_id" => @trace_id,
               "public_key" => "upstream",
               "sample_rate" => "0.25",
               "sample_rand" => "0.1",
               "sampled" => "true",
               "release" => "upstream-7",
               "environment" => "prod",
               "transaction" => "GET /upstream"
             }
    end

    test "drops entries that do not decode and keeps the rest", %{bypass: bypass} do
      put_test_config(environment_name: "test", traces_sample_rate: 1.0)
      ref = setup_bypass_envelope_collector(bypass, type: "transaction")

      continue_sentry_trace(
        "sentry-trace_id=#{@trace_id},sentry-public_key=upstream," <>
          "sentry-release=%FF,sentry-environment=%zz,sentry-transaction=abc%,sentry-sampled=true"
      )

      Tracer.with_span "job.run" do
        Process.sleep(1)
      end

      assert [{trace, _tx}] = collect_transaction_envelopes(ref, 1)

      assert trace == %{
               "trace_id" => @trace_id,
               "public_key" => "upstream",
               "environment" => "%zz",
               "transaction" => "abc%",
               "sampled" => "true"
             }
    end

    test "is this service's own when the baggage carries no Sentry entries", %{bypass: bypass} do
      put_test_config(environment_name: "test", traces_sample_rate: 1.0)
      ref = setup_bypass_envelope_collector(bypass, type: "transaction")

      continue_sentry_trace("other-vendor=x")

      Tracer.with_span "job.run" do
        Process.sleep(1)
      end

      assert [{trace, _tx}] = collect_transaction_envelopes(ref, 1)

      assert %{
               "trace_id" => @trace_id,
               "public_key" => "public",
               "sample_rate" => "1.0",
               "sampled" => "true",
               "environment" => "test",
               "transaction" => "job.run"
             } = trace
    end

    # This SDK's propagator sends a baggage of only `sentry-org_id` when it
    # heads a trace, so a hop between two services on it arrives like this.
    test "is this service's own when the baggage carries only an organization ID",
         %{bypass: bypass} do
      put_test_config(environment_name: "test", traces_sample_rate: 1.0)
      ref = setup_bypass_envelope_collector(bypass, type: "transaction")

      continue_sentry_trace("sentry-org_id=42")

      Tracer.with_span "job.run" do
        Process.sleep(1)
      end

      assert [{trace, _tx}] = collect_transaction_envelopes(ref, 1)

      assert %{"trace_id" => @trace_id, "public_key" => "public", "transaction" => "job.run"} =
               trace

      refute Map.has_key?(trace, "org_id")
    end
  end

  defp continue_sentry_trace(baggage) do
    carrier = %{"sentry-trace" => "#{@trace_id}-#{@remote_span_id}-1", "baggage" => baggage}
    getter = fn key, carrier -> Map.get(carrier, key, :undefined) end

    :otel_ctx.get_current()
    |> Sentry.OpenTelemetry.Propagator.extract(carrier, nil, getter, [])
    |> :otel_ctx.attach()

    :ok
  end

  defp continue_remote_trace do
    :otel_propagator_text_map.extract([
      {"traceparent", "00-#{@trace_id}-#{@remote_span_id}-01"}
    ])

    :ok
  end
end
