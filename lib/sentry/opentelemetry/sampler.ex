if Sentry.OpenTelemetry.VersionChecker.tracing_compatible?() do
  defmodule Sentry.OpenTelemetry.Sampler do
    @moduledoc false

    alias OpenTelemetry.{Span, Tracer}
    alias Sentry.Callback
    alias Sentry.ClientReport
    alias SamplingContext

    @behaviour :otel_sampler

    @sentry_sample_rate_key "sentry-sample_rate"
    @sentry_sample_rand_key "sentry-sample_rand"
    @sentry_sampled_key "sentry-sampled"

    @impl true
    def setup(config) do
      config
    end

    @impl true
    def description(_) do
      "SentrySampler"
    end

    @impl true
    def should_sample(
          ctx,
          trace_id,
          _links,
          span_name,
          span_kind,
          attributes,
          config
        ) do
      {result, discard_reason} =
        if config[:drop] && span_name in config[:drop] do
          {{:drop, [], []}, :sample_rate}
        else
          traces_sampler = Sentry.Config.traces_sampler()
          traces_sample_rate = Sentry.Config.traces_sample_rate()

          case get_trace_sampling_decision(ctx) do
            {:inherit, trace_sampled, tracestate} ->
              decision = if trace_sampled, do: :record_and_sample, else: :drop
              {{decision, [], tracestate}, :sample_rate}

            :no_trace ->
              if traces_sampler do
                sampling_context =
                  build_sampling_context(nil, span_name, span_kind, attributes, trace_id)

                make_sampler_decision(traces_sampler, sampling_context, traces_sample_rate)
              else
                {make_sampling_decision(traces_sample_rate), :sample_rate}
              end
          end
        end

      case result do
        {:drop, _, _} ->
          record_discarded_transaction(discard_reason)
          result

        _ ->
          result
      end
    end

    defp get_trace_sampling_decision(ctx) do
      case Tracer.current_span_ctx(ctx) do
        :undefined ->
          :no_trace

        span_ctx ->
          tracestate = Span.tracestate(span_ctx)
          trace_sampled = get_tracestate_value(tracestate, @sentry_sampled_key)

          case trace_sampled do
            "true" ->
              {:inherit, true, tracestate}

            "false" ->
              {:inherit, false, tracestate}

            nil ->
              :no_trace
          end
      end
    end

    defp make_sampling_decision(sample_rate) do
      cond do
        is_nil(sample_rate) ->
          {:drop, [], []}

        sample_rate == 0.0 ->
          tracestate = build_tracestate(sample_rate, 1.0, false)
          {:drop, [], tracestate}

        sample_rate == 1.0 ->
          tracestate = build_tracestate(sample_rate, 0.0, true)
          {:record_and_sample, [], tracestate}

        true ->
          random_value = :rand.uniform()
          sampled = random_value < sample_rate
          tracestate = build_tracestate(sample_rate, random_value, sampled)
          decision = if sampled, do: :record_and_sample, else: :drop
          {decision, [], tracestate}
      end
    end

    defp build_tracestate(sample_rate, random_value, sampled) do
      [
        {@sentry_sample_rate_key, Float.to_string(sample_rate)},
        {@sentry_sample_rand_key, Float.to_string(random_value)},
        {@sentry_sampled_key, to_string(sampled)}
      ]
    end

    defp get_tracestate_value({:tracestate, tracestate}, key) do
      get_tracestate_value(tracestate, key)
    end

    defp get_tracestate_value(tracestate, key) when is_list(tracestate) do
      case List.keyfind(tracestate, key, 0) do
        {^key, value} -> value
        nil -> nil
      end
    end

    defp build_sampling_context(parent_sampled, span_name, _span_kind, attributes, trace_id) do
      transaction_context = %{
        name: span_name,
        op: span_name,
        trace_id: trace_id,
        attributes: attributes
      }

      sampling_context = %SamplingContext{
        transaction_context: transaction_context,
        parent_sampled: parent_sampled
      }

      sampling_context
    end

    defp make_sampler_decision(traces_sampler, sampling_context, fallback_sample_rate) do
      invocation = Callback.to_fun(:traces_sampler, traces_sampler, [sampling_context])

      case Callback.run(:traces_sampler, invocation) do
        {:ok, result} ->
          sample_rate =
            case Callback.validate(
                   :traces_sampler,
                   normalize_sampler_result(result),
                   &valid_sample_rate?/1,
                   "a boolean or a float between 0.0 and 1.0"
                 ) do
              {:ok, sample_rate} -> sample_rate
              :invalid -> 0.0
            end

          {make_sampling_decision(sample_rate), :sample_rate}

        :failed ->
          make_fallback_decision(fallback_sample_rate)
      end
    end

    defp valid_sample_rate?(sample_rate) do
      is_float(sample_rate) and sample_rate >= 0.0 and sample_rate <= 1.0
    end

    defp make_fallback_decision(nil) do
      {{:drop, [], [{@sentry_sampled_key, "false"}]}, :callback_error}
    end

    defp make_fallback_decision(fallback_sample_rate) do
      {make_sampling_decision(fallback_sample_rate), :sample_rate}
    end

    defp normalize_sampler_result(true), do: 1.0
    defp normalize_sampler_result(false), do: 0.0
    defp normalize_sampler_result(rate), do: rate

    defp record_discarded_transaction(reason) do
      ClientReport.Sender.record_discarded_events(reason, "transaction")

      # A dropped transaction also drops its spans. The sampling decision happens
      # before any child spans are recorded, so only the transaction itself is
      # extracted as a span (0 spans + 1).
      # https://develop.sentry.dev/sdk/telemetry/client-reports/#span-outcomes
      ClientReport.Sender.record_discarded_events(reason, "span")
    end
  end
end
