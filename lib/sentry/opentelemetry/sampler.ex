if Code.ensure_loaded?(:otel_sampler) do
  defmodule Sentry.OpenTelemetry.Sampler do
    @moduledoc false

    def setup(config) do
      config
    end

    def description(_) do
      "SentrySampler"
    end

    def should_sample(
          _ctx,
          _trace_id,
          _links,
          span_name,
          _span_kind,
          _attributes,
          config
        ) do
      if span_name in config[:drop] do
        {:drop, [], []}
      else
        {:record_and_sample, [], []}
      end
    end
  end
end
