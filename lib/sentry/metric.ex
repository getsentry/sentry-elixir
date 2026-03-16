defmodule Sentry.Metric do
  @moduledoc """
  Represents a metric that can be sent to Sentry.

  Metrics follow the Sentry Metrics Protocol as defined in:
  <https://develop.sentry.dev/sdk/telemetry/metrics/>

  This module is used by `Sentry.Metrics` to create and send metric data to Sentry.
  """
  @moduledoc since: "13.0.0"

  alias Sentry.Config

  @type metric_type :: :counter | :gauge | :distribution

  @typedoc """
  A metric struct.
  """
  @type t :: %__MODULE__{
          type: metric_type(),
          name: String.t(),
          value: number(),
          timestamp: float(),
          trace_id: String.t() | nil,
          span_id: String.t() | nil,
          unit: String.t() | nil,
          attributes: map()
        }

  @enforce_keys [:type, :name, :value, :timestamp]
  defstruct [
    :type,
    :name,
    :value,
    :timestamp,
    :trace_id,
    :span_id,
    :unit,
    attributes: %{}
  ]

  @sdk_version Mix.Project.config()[:version]

  @doc """
  Attaches default attributes to a metric.

  This adds Sentry-specific attributes like environment, release, SDK info, and server name.
  Per the Sentry Metrics spec, default attributes should be attached before the
  `before_send_metric` callback is applied (step 5 before step 6).
  """
  @spec attach_default_attributes(t()) :: t()
  def attach_default_attributes(%__MODULE__{} = metric) do
    default_attrs = %{
      "sentry.sdk.name" => "sentry.elixir",
      "sentry.sdk.version" => @sdk_version
    }

    # Add optional attributes if configured
    default_attrs =
      default_attrs
      |> maybe_put_attr("sentry.environment", Config.environment_name())
      |> maybe_put_attr("sentry.release", Config.release())
      |> maybe_put_attr("server.address", Config.server_name())

    # Merge with user attributes (user attributes take precedence)
    %{metric | attributes: Map.merge(default_attrs, metric.attributes)}
  end

  defp maybe_put_attr(attrs, _key, nil), do: attrs
  defp maybe_put_attr(attrs, key, value), do: Map.put(attrs, key, value)

  @doc """
  Converts a metric to a map suitable for JSON encoding.

  The output matches the Sentry metrics schema with top-level fields: timestamp, type, name,
  value, unit, trace_id, span_id, and attributes. The attributes are formatted with type
  information as required by the protocol.
  """
  @spec to_map(t()) :: %{optional(atom()) => term()}
  def to_map(%__MODULE__{} = metric) do
    %{
      timestamp: metric.timestamp,
      type: to_string(metric.type),
      name: metric.name,
      value: metric.value,
      attributes: format_attributes(metric.attributes)
    }
    |> maybe_put(:unit, metric.unit)
    |> maybe_put(:trace_id, metric.trace_id)
    |> maybe_put(:span_id, metric.span_id)
  end

  @doc false
  @spec call_before_send_callback(t(), function() | {module(), atom()}) :: t() | nil
  def call_before_send_callback(metric, function) when is_function(function, 1) do
    function.(metric)
  rescue
    error ->
      require Logger
      Logger.warning("before_send_metric callback failed: #{inspect(error)}")
      metric
  end

  def call_before_send_callback(metric, {mod, fun}) do
    apply(mod, fun, [metric])
  rescue
    error ->
      require Logger
      Logger.warning("before_send_metric callback failed: #{inspect(error)}")
      metric
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  ## Helpers

  # Format attributes to the protocol format with type information
  defp format_attributes(attributes) when is_map(attributes) do
    Enum.into(attributes, %{}, fn {key, value} ->
      safe_value = sanitize_attribute_value(value)
      {to_string(key), %{value: safe_value, type: attribute_type(safe_value)}}
    end)
  end

  # Converts values to JSON-safe attribute types.
  # Primitives (string, boolean, integer, float) pass through unchanged.
  # Atoms are converted to strings. All other types (structs, maps, lists,
  # tuples, PIDs, etc.) are converted to their inspect() representation.
  # Note: is_boolean must come before is_atom since true/false are atoms
  defp sanitize_attribute_value(value) when is_binary(value), do: value
  defp sanitize_attribute_value(value) when is_boolean(value), do: value
  defp sanitize_attribute_value(value) when is_atom(value), do: Atom.to_string(value)
  defp sanitize_attribute_value(value) when is_integer(value), do: value
  defp sanitize_attribute_value(value) when is_float(value), do: value
  defp sanitize_attribute_value(value), do: inspect(value)

  defp attribute_type(value) when is_boolean(value), do: "boolean"
  defp attribute_type(value) when is_integer(value), do: "integer"
  defp attribute_type(value) when is_float(value), do: "double"
  defp attribute_type(_value), do: "string"
end
