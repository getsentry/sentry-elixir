defmodule Sentry.Opentelemetry.SamplerTest do
  use Sentry.Case, async: false

  alias Sentry.OpenTelemetry.Sampler
  alias Sentry.ClientReport

  import Sentry.TestHelpers

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

  describe "span name dropping" do
    test "drops spans with the given name and records discarded event" do
      :sys.replace_state(ClientReport.Sender, fn _ -> %{} end)

      test_ctx = create_test_span_context()

      assert {:drop, [], []} =
               Sampler.should_sample(test_ctx, nil, nil, "Elixir.Oban.Stager process", nil, nil,
                 drop: ["Elixir.Oban.Stager process"]
               )

      state = :sys.get_state(ClientReport.Sender)
      assert state == %{{:sample_rate, "transaction"} => 1}
    end

    test "records and samples spans not in drop list" do
      put_test_config(traces_sample_rate: 1.0)

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

      put_test_config(traces_sample_rate: 0.0)

      test_ctx = create_test_span_context()

      assert {:drop, [], tracestate} =
               Sampler.should_sample(test_ctx, 123, nil, "test span", nil, nil, drop: [])

      assert {"sentry-sample_rate", "0.0"} in tracestate
      assert {"sentry-sampled", "false"} in tracestate

      state = :sys.get_state(ClientReport.Sender)
      assert state == %{{:sample_rate, "transaction"} => 1}
    end

    test "always samples when sample rate is 1.0" do
      put_test_config(traces_sample_rate: 1.0)

      test_ctx = create_test_span_context()

      assert {:record_and_sample, [], tracestate} =
               Sampler.should_sample(test_ctx, 123, nil, "test span", nil, nil, drop: [])

      assert {"sentry-sample_rate", "1.0"} in tracestate
      assert {"sentry-sampled", "true"} in tracestate
    end

    test "different trace_ids produce different sampling decisions" do
      put_test_config(traces_sample_rate: 0.5)

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

      put_test_config(traces_sample_rate: 0.001)

      Enum.each(1..50, fn trace_id ->
        test_ctx = create_test_span_context()
        Sampler.should_sample(test_ctx, trace_id, nil, "test span", nil, nil, drop: [])
      end)

      state = :sys.get_state(ClientReport.Sender)
      discarded_count = Map.get(state, {:sample_rate, "transaction"}, 0)
      assert discarded_count > 0, "Expected some spans to be dropped and recorded"
    end

    test "always drops when sample rate is nil (tracing disabled) and records discarded event" do
      :sys.replace_state(ClientReport.Sender, fn _ -> %{} end)

      put_test_config(traces_sample_rate: nil)

      test_ctx = create_test_span_context()

      assert {:drop, [], []} =
               Sampler.should_sample(test_ctx, 123, nil, "test span", nil, nil, drop: [])

      state = :sys.get_state(ClientReport.Sender)
      assert state == %{{:sample_rate, "transaction"} => 1}
    end
  end

  describe "trace-level sampling consistency" do
    defp create_span_context_with_tracestate(trace_id, tracestate) do
      {
        :span_ctx,
        trace_id,
        123_456_789,
        1,
        tracestate,
        true,
        false,
        true,
        nil
      }
    end

    test "all spans in trace inherit sampling decision to drop when trace was not sampled" do
      :sys.replace_state(ClientReport.Sender, fn _ -> %{} end)

      trace_id = 12_345_678_901_234_567_890_123_456_789_012

      trace_tracestate = [
        {"sentry-sample_rate", "1.0"},
        {"sentry-sample_rand", "0.5"},
        {"sentry-sampled", "false"}
      ]

      existing_span_ctx = create_span_context_with_tracestate(trace_id, trace_tracestate)

      ctx = :otel_ctx.new()
      ctx_with_span = :otel_tracer.set_current_span(ctx, existing_span_ctx)
      token = :otel_ctx.attach(ctx_with_span)

      try do
        result =
          Sampler.should_sample(ctx_with_span, trace_id, nil, "new span in trace", nil, nil,
            drop: []
          )

        assert {:drop, [], returned_tracestate} = result
        assert returned_tracestate == trace_tracestate

        state = :sys.get_state(ClientReport.Sender)
        assert state == %{{:sample_rate, "transaction"} => 1}
      after
        :otel_ctx.detach(token)
      end
    end

    test "all spans in trace inherit sampling decision to sample when trace was sampled" do
      trace_id = 12_345_678_901_234_567_890_123_456_789_012

      trace_tracestate = [
        {"sentry-sample_rate", "1.0"},
        {"sentry-sample_rand", "0.5"},
        {"sentry-sampled", "true"}
      ]

      existing_span_ctx = create_span_context_with_tracestate(trace_id, trace_tracestate)

      ctx = :otel_ctx.new()
      ctx_with_span = :otel_tracer.set_current_span(ctx, existing_span_ctx)
      token = :otel_ctx.attach(ctx_with_span)

      try do
        result =
          Sampler.should_sample(ctx_with_span, trace_id, nil, "new span in trace", nil, nil,
            drop: []
          )

        assert {:record_and_sample, [], returned_tracestate} = result
        assert returned_tracestate == trace_tracestate
      after
        :otel_ctx.detach(token)
      end
    end

    test "makes new sampling decision when no existing trace context" do
      put_test_config(traces_sample_rate: 1.0)

      test_ctx = create_test_span_context()

      assert {:record_and_sample, [], _tracestate} =
               Sampler.should_sample(test_ctx, 123, nil, "root span", nil, nil, drop: [])
    end

    test "makes new sampling decision when tracestate has no sentry sampling info" do
      trace_id = 12_345_678_901_234_567_890_123_456_789_012

      non_sentry_tracestate = [
        {"other-system", "some-value"}
      ]

      existing_span_ctx = create_span_context_with_tracestate(trace_id, non_sentry_tracestate)

      ctx = :otel_ctx.new()
      ctx_with_span = :otel_tracer.set_current_span(ctx, existing_span_ctx)
      token = :otel_ctx.attach(ctx_with_span)

      try do
        put_test_config(traces_sample_rate: 1.0)

        result =
          Sampler.should_sample(ctx_with_span, trace_id, nil, "span in external trace", nil, nil,
            drop: []
          )

        assert {:record_and_sample, [], new_tracestate} = result
        assert {"sentry-sampled", "true"} in new_tracestate
      after
        :otel_ctx.detach(token)
      end
    end

    test "trace_id parameter is now irrelevant for inheritance decisions" do
      trace_id = 12_345_678_901_234_567_890_123_456_789_012
      different_trace_id = 98_765_432_109_876_543_210_987_654_321_098

      trace_tracestate = [
        {"sentry-sample_rate", "1.0"},
        {"sentry-sample_rand", "0.5"},
        {"sentry-sampled", "false"}
      ]

      existing_span_ctx = create_span_context_with_tracestate(trace_id, trace_tracestate)

      ctx = :otel_ctx.new()
      ctx_with_span = :otel_tracer.set_current_span(ctx, existing_span_ctx)
      token = :otel_ctx.attach(ctx_with_span)

      try do
        result =
          Sampler.should_sample(ctx_with_span, different_trace_id, nil, "span", nil, nil,
            drop: []
          )

        assert {:drop, [], returned_tracestate} = result
        assert returned_tracestate == trace_tracestate
      after
        :otel_ctx.detach(token)
      end
    end
  end

  describe "tracestate management" do
    test "builds tracestate with correct format" do
      put_test_config(traces_sample_rate: 0.75)

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

  describe "traces_sampler functionality" do
    test "uses traces_sampler when configured" do
      sampler_fun = fn _sampling_context -> 0.5 end
      put_test_config(traces_sampler: sampler_fun)

      test_ctx = create_test_span_context()

      {decision, [], tracestate} =
        Sampler.should_sample(test_ctx, 123, nil, "test span", :server, %{}, drop: [])

      assert decision in [:record_and_sample, :drop]
      assert {"sentry-sample_rate", "0.5"} in tracestate
      assert {"sentry-sampled", _} = List.keyfind(tracestate, "sentry-sampled", 0)
    end

    test "traces_sampler receives correct sampling context" do
      {:ok, received_context} = Agent.start_link(fn -> nil end)

      sampler_fun = fn sampling_context ->
        Agent.update(received_context, fn _ -> sampling_context end)
        true
      end

      put_test_config(traces_sampler: sampler_fun)

      test_ctx = create_test_span_context()
      attributes = %{"http.method" => "GET", "http.url" => "http://example.com"}

      Sampler.should_sample(test_ctx, 123, nil, "GET /users", :server, attributes, drop: [])

      context = Agent.get(received_context, & &1)

      assert context[:parent_sampled] == nil
      assert context[:transaction_context][:name] == "GET /users"
      assert context[:transaction_context][:op] == "GET /users"
      assert context[:transaction_context][:trace_id] == 123
      assert context[:transaction_context][:attributes] == attributes

      Agent.stop(received_context)
    end

    test "traces_sampler can return boolean values" do
      put_test_config(traces_sampler: fn _ -> true end)
      test_ctx = create_test_span_context()

      assert {:record_and_sample, [], tracestate} =
               Sampler.should_sample(test_ctx, 123, nil, "test span", nil, %{}, drop: [])

      assert {"sentry-sampled", "true"} in tracestate

      put_test_config(traces_sampler: fn _ -> false end)

      assert {:drop, [], tracestate} =
               Sampler.should_sample(test_ctx, 123, nil, "test span", nil, %{}, drop: [])

      assert {"sentry-sampled", "false"} in tracestate
    end

    test "traces_sampler can return float values" do
      put_test_config(traces_sampler: fn _ -> 0.75 end)

      test_ctx = create_test_span_context()

      {decision, [], tracestate} =
        Sampler.should_sample(test_ctx, 123, nil, "test span", nil, %{}, drop: [])

      assert decision in [:record_and_sample, :drop]
      assert {"sentry-sample_rate", "0.75"} in tracestate
    end

    test "traces_sampler takes precedence over traces_sample_rate" do
      put_test_config(traces_sample_rate: 1.0, traces_sampler: fn _ -> false end)

      test_ctx = create_test_span_context()

      assert {:drop, [], _tracestate} =
               Sampler.should_sample(test_ctx, 123, nil, "test span", nil, %{}, drop: [])
    end

    test "child spans inherit parent sampling decision without calling traces_sampler" do
      {:ok, sampler_call_count} = Agent.start_link(fn -> 0 end)

      sampler_fun = fn _sampling_context ->
        Agent.update(sampler_call_count, &(&1 + 1))
        false
      end

      put_test_config(traces_sampler: sampler_fun)

      trace_tracestate = [
        {"sentry-sample_rate", "1.0"},
        {"sentry-sample_rand", "0.5"},
        {"sentry-sampled", "true"}
      ]

      existing_span_ctx = create_span_context_with_tracestate(123, trace_tracestate)

      ctx = :otel_ctx.new()
      ctx_with_span = :otel_tracer.set_current_span(ctx, existing_span_ctx)
      token = :otel_ctx.attach(ctx_with_span)

      try do
        result =
          Sampler.should_sample(ctx_with_span, 123, nil, "child span", nil, %{}, drop: [])

        assert {:record_and_sample, [], returned_tracestate} = result
        assert returned_tracestate == trace_tracestate

        call_count = Agent.get(sampler_call_count, & &1)
        assert call_count == 0
      after
        :otel_ctx.detach(token)
        Agent.stop(sampler_call_count)
      end
    end

    test "traces_sampler is only called for root spans" do
      {:ok, sampler_call_count} = Agent.start_link(fn -> 0 end)

      sampler_fun = fn _sampling_context ->
        Agent.update(sampler_call_count, &(&1 + 1))
        true
      end

      put_test_config(traces_sampler: sampler_fun)

      test_ctx = create_test_span_context()

      result = Sampler.should_sample(test_ctx, 123, nil, "root span", nil, %{}, drop: [])

      assert {:record_and_sample, [], _tracestate} = result

      call_count = Agent.get(sampler_call_count, & &1)
      assert call_count == 1

      Agent.stop(sampler_call_count)
    end

    test "handles traces_sampler errors gracefully" do
      put_test_config(traces_sampler: fn _ -> raise "sampler error" end)

      test_ctx = create_test_span_context()

      assert {:drop, [], _tracestate} =
               Sampler.should_sample(test_ctx, 123, nil, "test span", nil, %{}, drop: [])
    end

    test "supports MFA tuple for traces_sampler" do
      defmodule TestSampler do
        def sample(_sampling_context), do: 0.25
      end

      put_test_config(traces_sampler: {TestSampler, :sample})

      test_ctx = create_test_span_context()

      {decision, [], tracestate} =
        Sampler.should_sample(test_ctx, 123, nil, "test span", nil, %{}, drop: [])

      assert decision in [:record_and_sample, :drop]
      assert {"sentry-sample_rate", "0.25"} in tracestate
    end

    test "uses span name as operation and passes attributes" do
      {:ok, received_context} = Agent.start_link(fn -> nil end)

      sampler_fun = fn sampling_context ->
        Agent.update(received_context, fn _ -> sampling_context end)
        true
      end

      put_test_config(traces_sampler: sampler_fun)

      test_ctx = create_test_span_context()

      http_attributes = %{"http.method" => "POST"}

      Sampler.should_sample(test_ctx, 123, nil, "POST /api", :server, http_attributes, drop: [])

      context = Agent.get(received_context, & &1)
      assert context[:transaction_context][:op] == "POST /api"
      assert context[:transaction_context][:attributes] == http_attributes

      db_attributes = %{"db.system" => "postgresql"}

      Sampler.should_sample(test_ctx, 124, nil, "SELECT users", :client, db_attributes, drop: [])

      context = Agent.get(received_context, & &1)
      assert context[:transaction_context][:op] == "SELECT users"
      assert context[:transaction_context][:attributes] == db_attributes

      oban_attributes = %{"messaging.system" => :oban}

      Sampler.should_sample(test_ctx, 125, nil, "MyWorker", :consumer, oban_attributes, drop: [])

      context = Agent.get(received_context, & &1)
      assert context[:transaction_context][:op] == "MyWorker"
      assert context[:transaction_context][:attributes] == oban_attributes

      Agent.stop(received_context)
    end
  end
end
