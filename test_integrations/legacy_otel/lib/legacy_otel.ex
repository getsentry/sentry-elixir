defmodule LegacyOtel do
  def get_otel_versions do
    Application.loaded_applications()
    |> Enum.filter(fn {app, _desc, _vsn} ->
      app in [:opentelemetry, :opentelemetry_api, :opentelemetry_exporter, :opentelemetry_semantic_conventions]
    end)
    |> Enum.map(fn {app, _desc, vsn} -> {app, to_string(vsn)} end)
    |> Map.new()
  end

  def test_sentry_otel_integration do
    span_processor_defined? = Code.ensure_loaded?(Sentry.OpenTelemetry.SpanProcessor)
    sampler_defined? = Code.ensure_loaded?(Sentry.OpenTelemetry.Sampler)
    span_record_defined? = Code.ensure_loaded?(Sentry.OpenTelemetry.SpanRecord)

    version_compatible? = Sentry.OpenTelemetry.VersionChecker.tracing_compatible?()

    %{
      span_processor_defined: span_processor_defined?,
      sampler_defined: sampler_defined?,
      span_record_defined: span_record_defined?,
      version_compatible: version_compatible?,
      loaded_versions: get_otel_versions()
    }
  end
end
