defmodule PhoenixApp.DistributedTracesTest do
  use PhoenixAppWeb.ConnCase, async: false

  require OpenTelemetry.Tracer, as: Tracer

  import Sentry.TestHelpers

  @trace_id String.duplicate("a", 32)
  @remote_span_id String.duplicate("b", 16)

  setup do
    Sentry.Test.setup_sentry(collect_envelopes: true, traces_sample_rate: 1.0)
  end

  test "work continuing an upstream trace is reported with its instrumented spans", %{ref: ref} do
    :otel_propagator_text_map.extract([
      {"traceparent", "00-#{@trace_id}-#{@remote_span_id}-01"}
    ])

    Tracer.with_span "etl.sync" do
      PhoenixApp.Repo.query!("SELECT 1")
    end

    assert [tx] = collect_sentry_transactions(ref, 1, timeout: 500),
             "nothing was reported for work continuing an upstream trace"

    assert tx["transaction"] == "etl.sync"

    trace = tx["contexts"]["trace"]
    assert trace["trace_id"] == @trace_id
    assert trace["parent_span_id"] == @remote_span_id

    assert [db_span] = tx["spans"]
    assert db_span["op"] == "db"
    assert db_span["parent_span_id"] == trace["span_id"]
    assert db_span["trace_id"] == @trace_id
  end
end
