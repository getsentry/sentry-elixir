if Sentry.OpenTelemetry.VersionChecker.tracing_compatible?() do
  defmodule Sentry.OpenTelemetry.SpanRecord do
    @moduledoc false

    @type t :: %__MODULE__{}

    require Record
    require OpenTelemetry

    @fields Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl")
    Record.defrecordp(:span, @fields)

    defstruct @fields ++ [:origin]

    def new(span() = otel_span) do
      otel_attrs = span(otel_span)

      {:attributes, _, _, _, attributes} = otel_attrs[:attributes]

      origin =
        case otel_attrs[:instrumentation_scope] do
          {:instrumentation_scope, origin, _version, _} ->
            origin

          _ ->
            :undefined
        end

      attrs =
        otel_attrs
        |> Keyword.delete(:attributes)
        |> Keyword.delete(:links)
        |> Keyword.merge(
          trace_id: cast_trace_id(otel_attrs[:trace_id]),
          span_id: cast_span_id(otel_attrs[:span_id]),
          parent_span_id: cast_span_id(otel_attrs[:parent_span_id]),
          origin: origin,
          start_time: cast_timestamp(otel_attrs[:start_time]),
          end_time: cast_timestamp(otel_attrs[:end_time]),
          attributes: normalize_attributes(attributes),
          links: cast_links(otel_attrs[:links])
        )
        |> Map.new()

      struct(__MODULE__, attrs)
    end

    defp normalize_attributes(attributes) do
      Enum.map(attributes, fn {key, value} ->
        {to_string(key), value}
      end)
      |> Map.new()
    end

    defp cast_span_id(nil), do: nil
    defp cast_span_id(:undefined), do: nil
    defp cast_span_id(span_id), do: bytes_to_hex(span_id, 16)

    defp cast_trace_id(trace_id), do: bytes_to_hex(trace_id, 32)

    defp cast_timestamp(:undefined), do: nil
    defp cast_timestamp(nil), do: nil

    defp cast_timestamp(timestamp) do
      nano_timestamp = OpenTelemetry.timestamp_to_nano(timestamp)
      {:ok, datetime} = DateTime.from_unix(div(nano_timestamp, 1_000_000), :millisecond)

      DateTime.to_iso8601(datetime)
    end

    defp cast_links(
           {:links, _count_limit, _attr_per_link_limit, _attr_value_length_limit, _dropped,
            links_list}
         ) do
      Enum.map(links_list, fn link ->
        case link do
          {:link, trace_id, span_id, {:attributes, _, _, _, attributes}, _tracestate} ->
            %{
              trace_id: cast_trace_id(trace_id),
              span_id: cast_span_id(span_id),
              attributes: normalize_attributes(attributes)
            }

          _ ->
            nil
        end
      end)
      |> Enum.reject(&is_nil/1)
    end

    defp cast_links(_), do: []

    defp bytes_to_hex(bytes, length) do
      case(:otel_utils.format_binary_string("~#{length}.16.0b", [bytes])) do
        {:ok, result} -> result
        {:error, _} -> raise "Failed to convert bytes to hex: #{inspect(bytes)}"
      end
    end
  end
end
