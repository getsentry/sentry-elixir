if Code.ensure_loaded?(:otel_sampler) do
  defmodule Sentry.OpenTelemetry.Sampler do
    @moduledoc false

    alias OpenTelemetry.{Span, Tracer}

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
          _span_kind,
          _attributes,
          config
        ) do
      if span_name in config[:drop] do
        {:drop, [], []}
      else
        sample_rate = Sentry.Config.traces_sample_rate()

        case get_parent_sampling_decision(ctx, trace_id) do
          {:inherit, parent_sampled, tracestate} ->
            decision = if parent_sampled, do: :record_and_sample, else: :drop
            {decision, [], tracestate}

          :no_parent ->
            make_sampling_decision(sample_rate)
        end
      end
    end

    defp get_parent_sampling_decision(ctx, trace_id) do
      case Tracer.current_span_ctx(ctx) do
        :undefined ->
          :no_parent

        span_ctx ->
          parent_trace_id = Span.trace_id(span_ctx)

          if parent_trace_id == trace_id do
            tracestate = Span.tracestate(span_ctx)
            parent_sampled = get_tracestate_value(tracestate, @sentry_sampled_key)

            case parent_sampled do
              "true" -> {:inherit, true, tracestate}
              "false" -> {:inherit, false, tracestate}
              nil -> :no_parent
            end
          else
            :no_parent
          end
      end
    end

    defp make_sampling_decision(sample_rate) do
      cond do
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
  end
end
