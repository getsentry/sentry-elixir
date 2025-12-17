defmodule Sentry.OpenTelemetry.PropagatorTest do
  use ExUnit.Case, async: true

  alias Sentry.OpenTelemetry.Propagator

  @moduletag skip: not Sentry.OpenTelemetry.VersionChecker.tracing_compatible?()

  if Sentry.OpenTelemetry.VersionChecker.tracing_compatible?() do
    require OpenTelemetry.Tracer, as: Tracer
    require Record

    @fields Record.extract(:span_ctx, from_lib: "opentelemetry_api/include/opentelemetry.hrl")
    Record.defrecordp(:span_ctx, @fields)

    describe "fields/1" do
      test "returns the header fields used by the propagator" do
        assert Propagator.fields([]) == ["sentry-trace", "baggage"]
      end
    end

    describe "inject/4" do
      test "injects sentry-trace header from current span context" do
        trace_id = 0x1234567890ABCDEF1234567890ABCDEF
        span_id = 0x1234567890ABCDEF
        trace_flags = 1

        span_context =
          span_ctx(
            trace_id: trace_id,
            span_id: span_id,
            trace_flags: trace_flags,
            tracestate: [],
            is_valid: true,
            is_remote: false
          )

        ctx = Tracer.set_current_span(:otel_ctx.new(), span_context)

        setter = fn key, value, carrier ->
          Map.put(carrier, key, value)
        end

        carrier = Propagator.inject(ctx, %{}, setter, [])

        assert Map.has_key?(carrier, "sentry-trace")
        sentry_trace = Map.get(carrier, "sentry-trace")

        assert sentry_trace =~ ~r/^[0-9a-f]{32}-[0-9a-f]{16}-[01]$/
        assert String.ends_with?(sentry_trace, "-1")
      end

      test "does not inject when no span context is present" do
        ctx = :otel_ctx.new()

        setter = fn key, value, carrier ->
          Map.put(carrier, key, value)
        end

        carrier = Propagator.inject(ctx, %{}, setter, [])

        assert carrier == %{}
      end
    end

    describe "extract/5" do
      test "extracts sentry-trace header and sets remote span context" do
        sentry_trace_header = "1234567890abcdef1234567890abcdef-1234567890abcdef-1"

        getter = fn key, _carrier ->
          case key do
            "sentry-trace" -> sentry_trace_header
            "baggage" -> :undefined
            _ -> :undefined
          end
        end

        ctx = Propagator.extract(:otel_ctx.new(), %{}, nil, getter, [])

        span_ctx = Tracer.current_span_ctx(ctx)
        assert span_ctx != :undefined

        expected_trace_id = 0x1234567890ABCDEF1234567890ABCDEF
        expected_span_id = 0x1234567890ABCDEF

        assert span_ctx(span_ctx, :trace_id) == expected_trace_id
        assert span_ctx(span_ctx, :span_id) == expected_span_id
        assert span_ctx(span_ctx, :trace_flags) == 1
        assert span_ctx(span_ctx, :is_remote) == true
      end

      test "extracts sentry-trace without sampled flag" do
        sentry_trace_header = "1234567890abcdef1234567890abcdef-1234567890abcdef"

        getter = fn key, _carrier ->
          case key do
            "sentry-trace" -> sentry_trace_header
            _ -> :undefined
          end
        end

        ctx = Propagator.extract(:otel_ctx.new(), %{}, nil, getter, [])

        span_ctx = Tracer.current_span_ctx(ctx)
        assert span_ctx != :undefined

        assert span_ctx(span_ctx, :trace_flags) == 1
        assert span_ctx(span_ctx, :is_remote) == true
      end

      test "handles missing sentry-trace header" do
        getter = fn _key, _carrier -> :undefined end

        ctx = Propagator.extract(:otel_ctx.new(), %{}, nil, getter, [])

        assert Tracer.current_span_ctx(ctx) == :undefined
      end

      test "handles invalid sentry-trace header format" do
        invalid_headers = [
          "invalid",
          "1234-5678",
          "toolong1234567890abcdef1234567890abcdef-1234567890abcdef-1"
        ]

        for invalid_header <- invalid_headers do
          getter = fn key, _carrier ->
            case key do
              "sentry-trace" -> invalid_header
              _ -> :undefined
            end
          end

          ctx = Propagator.extract(:otel_ctx.new(), %{}, nil, getter, [])

          assert Tracer.current_span_ctx(ctx) == :undefined
        end
      end

      test "extracts and stores baggage header" do
        sentry_trace_header = "1234567890abcdef1234567890abcdef-1234567890abcdef-1"

        baggage_header =
          "sentry-trace_id=771a43a4192642f0b136d5159a501700," <>
            "sentry-public_key=49d0f7386ad645858ae85020e393bef3," <>
            "sentry-sample_rate=0.01337,sentry-user_id=Am%C3%A9lie"

        getter = fn key, _carrier ->
          case key do
            "sentry-trace" -> sentry_trace_header
            "baggage" -> baggage_header
            _ -> :undefined
          end
        end

        ctx = Propagator.extract(:otel_ctx.new(), %{}, nil, getter, [])

        stored_baggage = :otel_ctx.get_value(ctx, :"sentry-baggage", :not_found)
        assert stored_baggage == baggage_header
      end

      test "handles missing baggage header" do
        sentry_trace_header = "1234567890abcdef1234567890abcdef-1234567890abcdef-1"

        getter = fn key, _carrier ->
          case key do
            "sentry-trace" -> sentry_trace_header
            _ -> :undefined
          end
        end

        ctx = Propagator.extract(:otel_ctx.new(), %{}, nil, getter, [])

        stored_baggage = :otel_ctx.get_value(ctx, :"sentry-baggage", :not_found)
        assert stored_baggage == :not_found
      end
    end

    describe "baggage propagation" do
      test "injects baggage from context" do
        trace_id = 0x1234567890ABCDEF1234567890ABCDEF
        span_id = 0x1234567890ABCDEF
        trace_flags = 1
        baggage_value = "sentry-trace_id=771a43a4192642f0b136d5159a501700,sentry-release=1.0.0"

        span_context =
          span_ctx(
            trace_id: trace_id,
            span_id: span_id,
            trace_flags: trace_flags,
            tracestate: [],
            is_valid: true,
            is_remote: false
          )

        ctx =
          :otel_ctx.new()
          |> Tracer.set_current_span(span_context)
          |> :otel_ctx.set_value(:"sentry-baggage", baggage_value)

        setter = fn key, value, carrier ->
          Map.put(carrier, key, value)
        end

        carrier = Propagator.inject(ctx, %{}, setter, [])

        assert Map.has_key?(carrier, "sentry-trace")
        assert Map.get(carrier, "baggage") == baggage_value
      end

      test "does not inject baggage when not in context" do
        trace_id = 0x1234567890ABCDEF1234567890ABCDEF
        span_id = 0x1234567890ABCDEF
        trace_flags = 1

        span_context =
          span_ctx(
            trace_id: trace_id,
            span_id: span_id,
            trace_flags: trace_flags,
            tracestate: [],
            is_valid: true,
            is_remote: false
          )

        ctx = Tracer.set_current_span(:otel_ctx.new(), span_context)

        setter = fn key, value, carrier ->
          Map.put(carrier, key, value)
        end

        carrier = Propagator.inject(ctx, %{}, setter, [])

        assert Map.has_key?(carrier, "sentry-trace")
        assert not Map.has_key?(carrier, "baggage")
      end
    end

    describe "integration with OpenTelemetry" do
      test "round-trip inject and extract preserves trace context" do
        Tracer.with_span "test_span" do
          ctx = :otel_ctx.get_current()
          span_ctx = Tracer.current_span_ctx(ctx)

          original_trace_id = span_ctx(span_ctx, :trace_id)
          original_span_id = span_ctx(span_ctx, :span_id)

          setter = fn key, value, carrier ->
            Map.put(carrier, key, value)
          end

          carrier = Propagator.inject(ctx, %{}, setter, [])

          getter = fn key, carrier ->
            Map.get(carrier, key, :undefined)
          end

          new_ctx = Propagator.extract(:otel_ctx.new(), carrier, nil, getter, [])
          new_span_ctx = Tracer.current_span_ctx(new_ctx)

          assert span_ctx(new_span_ctx, :trace_id) == original_trace_id
          assert span_ctx(new_span_ctx, :span_id) == original_span_id
        end
      end
    end
  end
end
