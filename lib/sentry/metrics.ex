defmodule Sentry.Metrics do
  @moduledoc """
  Public API for recording metrics and sending them to Sentry.

  Metrics follow the Sentry Metrics Protocol as defined in:
  <https://develop.sentry.dev/sdk/telemetry/metrics/>

  ## Metric Types

  The SDK supports three metric types:

    * **Counter** - Tracks a value that always increments
    * **Gauge** - Tracks a value that can go up or down
    * **Distribution** - Tracks a distribution of values for statistical aggregation

  ## Usage

      # Record a counter
      Sentry.Metrics.count("button.clicks", 1)
      Sentry.Metrics.count("button.clicks", 5, unit: "click", attributes: %{button_id: "submit"})

      # Record a gauge
      Sentry.Metrics.gauge("memory.usage", 1024, unit: "megabyte")

      # Record a distribution
      Sentry.Metrics.distribution("response.time", 42.5, unit: "millisecond")

  ## Configuration

  Metrics can be disabled globally via configuration:

      config :sentry, enable_metrics: false

  You can also filter metrics using the `:before_send_metric` callback:

      config :sentry,
        before_send_metric: fn metric ->
          # Drop metrics from test environments
          if metric.attributes["sentry.environment"] == "test", do: nil, else: metric
        end

  """
  @moduledoc since: "13.0.0"

  alias Sentry.{ClientReport, Config, Metric, TelemetryProcessor}

  @doc """
  Records a counter metric.

  Counters track values that always increment, such as the number of requests,
  button clicks, or error counts.

  ## Options

    * `:unit` - The unit of measurement (e.g., "click", "request"). Optional.
    * `:attributes` - A map of key-value pairs to attach to the metric. Optional.

  ## Examples

      Sentry.Metrics.count("button.clicks", 1)
      Sentry.Metrics.count("http.requests", 5, unit: "request", attributes: %{method: "GET"})

  """
  @spec count(String.t(), number(), keyword()) :: :ok
  def count(name, value, opts \\ []) when is_binary(name) and is_number(value) do
    record_metric(:counter, name, value, opts)
  end

  @doc """
  Records a gauge metric.

  Gauges track values that can go up or down, such as memory usage, active connections,
  or queue depth.

  ## Options

    * `:unit` - The unit of measurement (e.g., "byte", "connection"). Optional.
    * `:attributes` - A map of key-value pairs to attach to the metric. Optional.

  ## Examples

      Sentry.Metrics.gauge("memory.usage", 1024, unit: "megabyte")
      Sentry.Metrics.gauge("active.connections", 42, attributes: %{pool: "main"})

  """
  @spec gauge(String.t(), number(), keyword()) :: :ok
  def gauge(name, value, opts \\ []) when is_binary(name) and is_number(value) do
    record_metric(:gauge, name, value, opts)
  end

  @doc """
  Records a distribution metric.

  Distributions track a distribution of values for statistical aggregation,
  such as response times, payload sizes, or query durations.

  ## Options

    * `:unit` - The unit of measurement (e.g., "millisecond", "byte"). Optional.
    * `:attributes` - A map of key-value pairs to attach to the metric. Optional.

  ## Examples

      Sentry.Metrics.distribution("response.time", 42.5, unit: "millisecond")
      Sentry.Metrics.distribution("payload.size", 2048, unit: "byte", attributes: %{endpoint: "/api"})

  """
  @spec distribution(String.t(), number(), keyword()) :: :ok
  def distribution(name, value, opts \\ []) when is_binary(name) and is_number(value) do
    record_metric(:distribution, name, value, opts)
  end

  ## Private Functions

  defp record_metric(type, name, value, opts) do
    if Config.enable_metrics?() do
      unit = Keyword.get(opts, :unit)
      attributes = Keyword.get(opts, :attributes, %{})

      {trace_id, span_id} = extract_trace_context()
      trace_id = trace_id || generate_trace_id()

      # Build metric struct
      metric = %Metric{
        type: type,
        name: name,
        value: value,
        timestamp: System.system_time(:nanosecond) / 1_000_000_000,
        trace_id: trace_id,
        span_id: span_id,
        unit: unit,
        attributes: attributes
      }

      metric = Metric.attach_default_attributes(metric)

      case TelemetryProcessor.add(metric) do
        {:ok, {:rate_limited, data_category}} ->
          ClientReport.Sender.record_discarded_events(:ratelimit_backoff, data_category)

        :ok ->
          :ok
      end
    end

    :ok
  end

  defp extract_trace_context do
    case :otel_tracer.current_span_ctx() do
      :undefined ->
        {nil, nil}

      span_ctx ->
        trace_id = :otel_span.trace_id(span_ctx)
        span_id = :otel_span.span_id(span_ctx)

        if trace_id != 0 and span_id != 0 do
          {format_trace_id(trace_id), format_span_id(span_id)}
        else
          {nil, nil}
        end
    end
  rescue
    e in [UndefinedFunctionError, ArgumentError] ->
      require Logger
      Logger.debug("Failed to extract OpenTelemetry trace context: #{inspect(e)}")
      {nil, nil}
  end

  # Format trace_id as 32-character hex string
  defp format_trace_id(trace_id) when is_integer(trace_id) do
    trace_id
    |> Integer.to_string(16)
    |> String.pad_leading(32, "0")
    |> String.downcase()
  end

  # Format span_id as 16-character hex string
  defp format_span_id(span_id) when is_integer(span_id) do
    span_id
    |> Integer.to_string(16)
    |> String.pad_leading(16, "0")
    |> String.downcase()
  end

  # Generate a random trace_id as fallback when no active span exists
  # Per spec: "The trace_id field is REQUIRED on every metric payload"
  defp generate_trace_id do
    # Generate 16 random bytes (128 bits) and format as 32-char hex string
    :crypto.strong_rand_bytes(16)
    |> Base.encode16(case: :lower)
  end
end
