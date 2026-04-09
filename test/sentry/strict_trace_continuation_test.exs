defmodule Sentry.StrictTraceContinuationTest do
  use Sentry.Case, async: false

  import Sentry.TestHelpers

  describe "DSN org_id extraction" do
    test "extracts org_id from standard DSN host" do
      {:ok, dsn} = Sentry.DSN.parse("https://key@o1234.ingest.sentry.io/123")
      assert dsn.org_id == "1234"
    end

    test "extracts org_id from DSN with US region" do
      {:ok, dsn} = Sentry.DSN.parse("https://key@o42.ingest.us.sentry.io/123")
      assert dsn.org_id == "42"
    end

    test "returns nil for DSN without org_id" do
      {:ok, dsn} = Sentry.DSN.parse("https://key@sentry.io/123")
      assert dsn.org_id == nil
    end

    test "returns nil for self-hosted DSN" do
      {:ok, dsn} = Sentry.DSN.parse("https://key@my-sentry.example.com/123")
      assert dsn.org_id == nil
    end

    test "returns nil for localhost DSN" do
      {:ok, dsn} = Sentry.DSN.parse("http://key@localhost:9000/123")
      assert dsn.org_id == nil
    end
  end

  if Sentry.OpenTelemetry.VersionChecker.tracing_compatible?() do
    describe "should_continue_trace?/1" do
      # Decision matrix tests
      # | Baggage org | SDK org | strict=false | strict=true |
      # |-------------|---------|-------------|-------------|
      # | 1           | 1       | Continue    | Continue    |
      # | None        | 1       | Continue    | New trace   |
      # | 1           | None    | Continue    | New trace   |
      # | None        | None    | Continue    | Continue    |
      # | 1           | 2       | New trace   | New trace   |

      test "strict=false, matching orgs - continues trace" do
        put_test_config(
          dsn: "https://key@o1.ingest.sentry.io/123",
          strict_trace_continuation: false
        )

        assert Sentry.OpenTelemetry.Propagator.should_continue_trace?(
                 "sentry-trace_id=abc,sentry-org_id=1"
               )
      end

      test "strict=false, baggage missing org - continues trace" do
        put_test_config(
          dsn: "https://key@o1.ingest.sentry.io/123",
          strict_trace_continuation: false
        )

        assert Sentry.OpenTelemetry.Propagator.should_continue_trace?("sentry-trace_id=abc")
      end

      test "strict=false, SDK missing org - continues trace" do
        put_test_config(dsn: "https://key@sentry.io/123", strict_trace_continuation: false)

        assert Sentry.OpenTelemetry.Propagator.should_continue_trace?(
                 "sentry-trace_id=abc,sentry-org_id=1"
               )
      end

      test "strict=false, both missing org - continues trace" do
        put_test_config(dsn: "https://key@sentry.io/123", strict_trace_continuation: false)
        assert Sentry.OpenTelemetry.Propagator.should_continue_trace?("sentry-trace_id=abc")
      end

      test "strict=false, mismatched orgs - starts new trace" do
        put_test_config(
          dsn: "https://key@o2.ingest.sentry.io/123",
          strict_trace_continuation: false
        )

        refute Sentry.OpenTelemetry.Propagator.should_continue_trace?(
                 "sentry-trace_id=abc,sentry-org_id=1"
               )
      end

      test "strict=true, matching orgs - continues trace" do
        put_test_config(
          dsn: "https://key@o1.ingest.sentry.io/123",
          strict_trace_continuation: true
        )

        assert Sentry.OpenTelemetry.Propagator.should_continue_trace?(
                 "sentry-trace_id=abc,sentry-org_id=1"
               )
      end

      test "strict=true, baggage missing org - starts new trace" do
        put_test_config(
          dsn: "https://key@o1.ingest.sentry.io/123",
          strict_trace_continuation: true
        )

        refute Sentry.OpenTelemetry.Propagator.should_continue_trace?("sentry-trace_id=abc")
      end

      test "strict=true, SDK missing org - starts new trace" do
        put_test_config(dsn: "https://key@sentry.io/123", strict_trace_continuation: true)

        refute Sentry.OpenTelemetry.Propagator.should_continue_trace?(
                 "sentry-trace_id=abc,sentry-org_id=1"
               )
      end

      test "strict=true, both missing org - continues trace" do
        put_test_config(dsn: "https://key@sentry.io/123", strict_trace_continuation: true)
        assert Sentry.OpenTelemetry.Propagator.should_continue_trace?("sentry-trace_id=abc")
      end

      test "strict=true, mismatched orgs - starts new trace" do
        put_test_config(
          dsn: "https://key@o2.ingest.sentry.io/123",
          strict_trace_continuation: true
        )

        refute Sentry.OpenTelemetry.Propagator.should_continue_trace?(
                 "sentry-trace_id=abc,sentry-org_id=1"
               )
      end

      test "explicit org_id overrides DSN for validation" do
        put_test_config(
          dsn: "https://key@o1.ingest.sentry.io/123",
          org_id: "2",
          strict_trace_continuation: false
        )

        # SDK org is "2" (explicit), baggage org is "1" -> mismatch
        refute Sentry.OpenTelemetry.Propagator.should_continue_trace?(
                 "sentry-trace_id=abc,sentry-org_id=1"
               )
      end

      test "handles nil baggage" do
        put_test_config(
          dsn: "https://key@o1.ingest.sentry.io/123",
          strict_trace_continuation: false
        )

        assert Sentry.OpenTelemetry.Propagator.should_continue_trace?(nil)
      end

      test "handles empty baggage org_id value" do
        put_test_config(
          dsn: "https://key@o1.ingest.sentry.io/123",
          strict_trace_continuation: true
        )

        # Empty org_id in baggage should be treated as missing
        refute Sentry.OpenTelemetry.Propagator.should_continue_trace?(
                 "sentry-org_id=,sentry-trace_id=abc"
               )
      end
    end
  end
end
