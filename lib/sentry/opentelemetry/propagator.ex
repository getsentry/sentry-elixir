if Sentry.OpenTelemetry.VersionChecker.tracing_compatible?() do
  defmodule Sentry.OpenTelemetry.Propagator do
    @moduledoc """
    OpenTelemetry propagator for Sentry distributed tracing.

    This propagator implements the `sentry-trace` and `sentry-baggage` header propagation
    to enable distributed tracing across service boundaries. It follows the W3C Trace Context.
    """

    import Bitwise

    require Record
    require Logger
    require OpenTelemetry.Tracer, as: Tracer

    @behaviour :otel_propagator_text_map

    @fields Record.extract(:span_ctx, from_lib: "opentelemetry_api/include/opentelemetry.hrl")
    Record.defrecordp(:span_ctx, @fields)

    @sentry_trace_key "sentry-trace"
    @sentry_baggage_key "baggage"
    @sentry_trace_ctx_key :"sentry-trace"
    @sentry_baggage_ctx_key :"sentry-baggage"

    @impl true
    def fields(_opts) do
      [@sentry_trace_key, @sentry_baggage_key]
    end

    @impl true
    def inject(ctx, carrier, setter, _opts) do
      case Tracer.current_span_ctx(ctx) do
        span_ctx(trace_id: tid, span_id: sid, trace_flags: flags) when tid != 0 and sid != 0 ->
          sentry_trace_header = encode_sentry_trace({tid, sid, flags})
          carrier = setter.(@sentry_trace_key, sentry_trace_header, carrier)

          baggage_value = :otel_ctx.get_value(ctx, @sentry_baggage_ctx_key, :not_found)
          baggage_value = ensure_org_id_in_baggage(baggage_value)

          if is_binary(baggage_value) and baggage_value != :not_found do
            setter.(@sentry_baggage_key, baggage_value, carrier)
          else
            carrier
          end

        _ ->
          carrier
      end
    end

    @impl true
    def extract(ctx, carrier, _keys_fun, getter, _opts) do
      case getter.(@sentry_trace_key, carrier) do
        :undefined ->
          ctx

        header when is_binary(header) ->
          case decode_sentry_trace(header) do
            {:ok, {trace_hex, span_hex, sampled}} ->
              raw_baggage = getter.(@sentry_baggage_key, carrier)

              if should_continue_trace?(raw_baggage) do
                ctx =
                  ctx
                  |> :otel_ctx.set_value(@sentry_trace_ctx_key, {trace_hex, span_hex, sampled})
                  |> maybe_set_baggage(raw_baggage)

                trace_id = hex_to_int(trace_hex)
                span_id = hex_to_int(span_hex)

                # Create a remote, sampled parent span in the OTEL context.
                # We will set to "always sample" because Sentry will decide real sampling
                remote_span_ctx = :otel_tracer.from_remote_span(trace_id, span_id, 1)

                Tracer.set_current_span(ctx, remote_span_ctx)
              else
                sdk_org_id = Sentry.Config.effective_org_id()
                baggage_org_id = extract_baggage_org_id(raw_baggage)

                Logger.warning(
                  "[Sentry] Not continuing trace due to org ID mismatch (sdk: #{sdk_org_id}, incoming: #{baggage_org_id})"
                )

                ctx
              end

            {:error, _reason} ->
              ctx
          end

        _ ->
          ctx
      end
    end

    # Encode trace ID, span ID, and sampled flag to sentry-trace header format
    # Format: {trace_id}-{span_id}-{sampled}
    defp encode_sentry_trace({trace_id_int, span_id_int, trace_flags}) do
      sampled = if (trace_flags &&& 1) == 1, do: "1", else: "0"
      int_to_hex(trace_id_int, 16) <> "-" <> int_to_hex(span_id_int, 8) <> "-" <> sampled
    end

    # Decode sentry-trace header
    # Format: {trace_id}-{span_id}-{sampled} or {trace_id}-{span_id}
    defp decode_sentry_trace(
           <<trace_hex::binary-size(32), "-", span_hex::binary-size(16), "-",
             sampled::binary-size(1)>>
         ) do
      {:ok, {trace_hex, span_hex, sampled == "1"}}
    end

    defp decode_sentry_trace(<<trace_hex::binary-size(32), "-", span_hex::binary-size(16)>>) do
      {:ok, {trace_hex, span_hex, false}}
    end

    defp decode_sentry_trace(_invalid) do
      {:error, :invalid_format}
    end

    defp maybe_set_baggage(ctx, :undefined), do: ctx
    defp maybe_set_baggage(ctx, ""), do: ctx
    defp maybe_set_baggage(ctx, nil), do: ctx

    defp maybe_set_baggage(ctx, baggage) when is_binary(baggage) do
      :otel_ctx.set_value(ctx, @sentry_baggage_ctx_key, baggage)
    end

    # Convert hex string to integer
    defp hex_to_int(hex) do
      hex
      |> Base.decode16!(case: :mixed)
      |> :binary.decode_unsigned()
    end

    # Convert integer to hex string with padding
    defp int_to_hex(value, num_bytes) do
      value
      |> :binary.encode_unsigned()
      |> bin_pad_left(num_bytes)
      |> Base.encode16(case: :lower)
    end

    # Pad binary to specified number of bytes
    defp bin_pad_left(bin, total_bytes) do
      missing = total_bytes - byte_size(bin)
      if missing > 0, do: :binary.copy(<<0>>, missing) <> bin, else: bin
    end

    # Ensure sentry-org_id is present in the baggage string
    defp ensure_org_id_in_baggage(baggage) when is_binary(baggage) do
      org_id = Sentry.Config.effective_org_id()

      if org_id != nil and extract_baggage_org_id(baggage) == nil do
        baggage <> ",sentry-org_id=" <> org_id
      else
        baggage
      end
    end

    defp ensure_org_id_in_baggage(_baggage) do
      case Sentry.Config.effective_org_id() do
        nil -> :not_found
        org_id -> "sentry-org_id=" <> org_id
      end
    end

    # Extract sentry-org_id from a baggage header string
    defp extract_baggage_org_id(baggage) when is_binary(baggage) do
      baggage
      |> String.split(",")
      |> Enum.find_value(fn entry ->
        case String.split(String.trim(entry), "=", parts: 2) do
          ["sentry-org_id", value] ->
            trimmed = String.trim(value)
            if trimmed == "", do: nil, else: trimmed

          _ ->
            nil
        end
      end)
    end

    defp extract_baggage_org_id(_), do: nil

    # Determine whether to continue an incoming trace based on org_id validation
    @doc false
    def should_continue_trace?(raw_baggage) do
      sdk_org_id = Sentry.Config.effective_org_id()
      baggage_org_id = extract_baggage_org_id(raw_baggage)
      strict = Sentry.Config.strict_trace_continuation?()

      cond do
        # Mismatched org IDs always reject
        sdk_org_id != nil and baggage_org_id != nil and sdk_org_id != baggage_org_id ->
          false

        # In strict mode, both must be present and match (unless both are missing)
        strict and sdk_org_id == nil and baggage_org_id == nil ->
          true

        strict ->
          sdk_org_id != nil and sdk_org_id == baggage_org_id

        true ->
          true
      end
    end
  end
end
