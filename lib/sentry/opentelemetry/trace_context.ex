if Sentry.OpenTelemetry.VersionChecker.tracing_compatible?() do
  defmodule Sentry.OpenTelemetry.TraceContext do
    @moduledoc false

    @type t() :: {trace_id :: String.t(), span_id :: String.t()}

    @spec current() :: t() | nil
    def current do
      case :otel_tracer.current_span_ctx() do
        :undefined ->
          nil

        span_ctx ->
          trace_id = :otel_span.trace_id(span_ctx)
          span_id = :otel_span.span_id(span_ctx)

          if trace_id != 0 and span_id != 0 do
            {format_id(trace_id, 32), format_id(span_id, 16)}
          end
      end
    end

    defp format_id(id, length) do
      id
      |> Integer.to_string(16)
      |> String.pad_leading(length, "0")
      |> String.downcase()
    end
  end
end
