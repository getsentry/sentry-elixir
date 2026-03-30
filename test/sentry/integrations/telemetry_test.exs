defmodule Sentry.Integrations.TelemetryTest do
  use ExUnit.Case, async: true

  import Sentry.TestHelpers

  alias Sentry.Integrations.Telemetry

  describe "handle_event/4" do
    setup do
      setup_bypass()
    end

    test "reports errors", %{bypass: bypass} do
      ref = setup_bypass_envelope_collector(bypass, type: "event")

      handle_failure_event(:error, %RuntimeError{message: "oops"}, [])

      assert [event] = collect_envelopes(ref, 1) |> extract_events()

      assert event["tags"] == %{
               "telemetry_handler_id" => "my_handler",
               "event_name" => "[:my_app, :some_event]"
             }

      assert [exception] = event["exception"]
      assert exception["type"] == "RuntimeError"
      assert exception["value"] == "oops"
    end

    test "reports Erlang errors (normalized)", %{bypass: bypass} do
      ref = setup_bypass_envelope_collector(bypass, type: "event")

      handle_failure_event(:error, {:badmap, :foo}, [])

      assert [event] = collect_envelopes(ref, 1) |> extract_events()

      assert event["tags"] == %{
               "telemetry_handler_id" => "my_handler",
               "event_name" => "[:my_app, :some_event]"
             }

      assert [exception] = event["exception"]
      assert exception["type"] == "BadMapError"
      assert exception["value"] =~ "expected a map, got:"
      assert exception["value"] =~ ":foo"
    end

    for kind <- [:throw, :exit] do
      test "reports #{kind}s", %{bypass: bypass} do
        ref = setup_bypass_envelope_collector(bypass, type: "event")

        handle_failure_event(unquote(kind), :foo, [])

        assert [event] = collect_envelopes(ref, 1) |> extract_events()

        assert event["message"]["message"] == "Telemetry handler %s failed"
        assert event["message"]["formatted"] == "Telemetry handler my_handler failed"

        assert event["tags"] == %{
                 "telemetry_handler_id" => "my_handler",
                 "event_name" => "[:my_app, :some_event]"
               }

        assert event["extra"] == %{"kind" => inspect(unquote(kind)), "reason" => ":foo"}

        assert event["exception"] == []
      end
    end
  end

  defp handle_failure_event(kind, reason, stacktrace) do
    Telemetry.handle_event(
      [:telemetry, :handler, :failure],
      %{system_time: System.system_time(:native), monotonic_time: System.monotonic_time(:native)},
      %{
        handler_id: "my_handler",
        handler_config: %{my_key: "my value"},
        event_name: [:my_app, :some_event],
        kind: kind,
        reason: reason,
        stacktrace: stacktrace
      },
      :no_config
    )
  end
end
