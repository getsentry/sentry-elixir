if Code.ensure_loaded?(:otel_sampler) do
  defmodule Sentry.OpenTelemetry.Sampler do
    @moduledoc false

    alias OpenTelemetry.{Span, Tracer}
    alias Sentry.ClientReport
    alias SamplingContext

    require Logger

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
      result =
        if config[:drop] && span_name in config[:drop] do
          {:drop, [], []}
        else
          traces_sampler = Sentry.Config.traces_sampler()
          traces_sample_rate = Sentry.Config.traces_sample_rate()

          case get_trace_sampling_decision(ctx) do
            {:inherit, trace_sampled, tracestate} ->
              decision = if trace_sampled, do: :record_and_sample, else: :drop
              {decision, [], tracestate}

            :no_trace ->
              if traces_sampler do
                sampling_context =
                  build_sampling_context(nil, span_name, span_kind, attributes, trace_id)

                make_sampler_decision(traces_sampler, sampling_context)
              else
                make_sampling_decision(traces_sample_rate)
              end
          end
        end

      case result do
        {:drop, _, _} ->
          record_discarded_transaction()
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

    defp make_sampler_decision(traces_sampler, sampling_context) do
      try do
        result = call_traces_sampler(traces_sampler, sampling_context)
        sample_rate = normalize_sampler_result(result)

        if is_float(sample_rate) and sample_rate >= 0.0 and sample_rate <= 1.0 do
          make_sampling_decision(sample_rate)
        else
          Logger.warning(
            "traces_sampler function returned an invalid sample rate: #{inspect(sample_rate)}"
          )

          make_sampling_decision(0.0)
        end
      rescue
        error ->
          Logger.warning("traces_sampler function failed: #{inspect(error)}")

          make_sampling_decision(0.0)
      end
    end

    defp call_traces_sampler(fun, sampling_context) when is_function(fun, 1) do
      fun.(sampling_context)
    end

    defp call_traces_sampler({module, function}, sampling_context) do
      apply(module, function, [sampling_context])
    end

    defp normalize_sampler_result(true), do: 1.0
    defp normalize_sampler_result(false), do: 0.0
    defp normalize_sampler_result(rate), do: rate

    defp record_discarded_transaction() do
      ClientReport.Sender.record_discarded_events(:sample_rate, "transaction")
    end
  end
end
