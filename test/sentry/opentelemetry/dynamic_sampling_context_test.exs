defmodule Sentry.OpenTelemetry.DynamicSamplingContextTest do
  use Sentry.Case, async: false

  import Sentry.TestHelpers

  alias Sentry.OpenTelemetry.DynamicSamplingContext
  alias Sentry.OpenTelemetry.SpanRecord

  describe "from_baggage/1" do
    test "takes the sentry- members of the baggage, as they are" do
      assert DynamicSamplingContext.from_baggage(
               "sentry-trace_id=abc,sentry-sample_rate=0.25,other-vendor=x,sentry-sampled=true"
             ) == %{"trace_id" => "abc", "sample_rate" => "0.25", "sampled" => "true"}
    end

    test "tolerates whitespace around members, keys and values" do
      assert DynamicSamplingContext.from_baggage(
               " sentry-trace_id = abc ,\tsentry-sample_rate\t=\t0.25\t"
             ) == %{"trace_id" => "abc", "sample_rate" => "0.25"}
    end

    test "drops a member's properties and percent-decodes its value" do
      assert DynamicSamplingContext.from_baggage(
               "sentry-trace_id=abc,sentry-transaction=GET%20%2Fusers;prop=1;other"
             ) == %{"trace_id" => "abc", "transaction" => "GET /users"}
    end

    test "drops members that are no UTF-8 after decoding and members without a value" do
      assert DynamicSamplingContext.from_baggage(
               "sentry-trace_id=abc,sentry-release=%FF,sentry-,sentry-environment,sentry-user=%zz%"
             ) == %{"trace_id" => "abc", "user" => "%zz%"}
    end

    test "is nil without a trace ID, the least a context has" do
      assert DynamicSamplingContext.from_baggage("sentry-org_id=42") == nil
      assert DynamicSamplingContext.from_baggage("other-vendor=x") == nil
      assert DynamicSamplingContext.from_baggage("") == nil
      assert DynamicSamplingContext.from_baggage(nil) == nil
    end
  end

  describe "build/2" do
    test "is the sampler's decision from the tracestate and this SDK's identity" do
      put_test_config(
        dsn: "http://public:secret@localhost:1/1",
        environment_name: "test",
        release: "1.2.3",
        org_id: "42"
      )

      span_record = %SpanRecord{
        trace_id: "abc",
        tracestate:
          {:tracestate,
           [
             {"sentry-sample_rate", "0.25"},
             {"sentry-sample_rand", "0.1"},
             {"sentry-sampled", "true"}
           ]}
      }

      assert DynamicSamplingContext.build(span_record, "GET /users") == %{
               "trace_id" => "abc",
               "public_key" => "public",
               "sample_rate" => "0.25",
               "sample_rand" => "0.1",
               "sampled" => "true",
               "release" => "1.2.3",
               "environment" => "test",
               "transaction" => "GET /users",
               "org_id" => "42"
             }
    end

    test "leaves out what is not known" do
      put_test_config(dsn: nil, environment_name: "test", release: nil, org_id: nil)
      span_record = %SpanRecord{trace_id: "abc", tracestate: []}

      assert DynamicSamplingContext.build(span_record, "job.run") == %{
               "trace_id" => "abc",
               "environment" => "test",
               "transaction" => "job.run"
             }
    end
  end
end
