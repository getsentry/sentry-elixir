defmodule Sentry.Integrations.TelemetryTest do
  use ExUnit.Case, async: true

  import Sentry.Test.Assertions

  alias Sentry.Integrations.Telemetry
  alias Sentry.Test, as: SentryTest

  @tags %{
    telemetry_handler_id: "my_handler",
    event_name: "[:my_app, :some_event]"
  }

  describe "handle_event/4" do
    setup do
      SentryTest.setup_sentry()
    end

    test "reports errors" do
      handle_failure_event(:error, %RuntimeError{message: "oops"}, [])

      event = assert_sentry_report(:event, tags: @tags)

      assert [exception] = event.exception
      assert exception.type == "RuntimeError"
      assert exception.value == "oops"
    end

    test "reports Erlang errors (normalized)" do
      handle_failure_event(:error, {:badmap, :foo}, [])

      event = assert_sentry_report(:event, tags: @tags)

      assert [exception] = event.exception
      assert exception.type == "BadMapError"
      assert exception.value =~ "expected a map, got:"
      assert exception.value =~ ":foo"
    end

    for kind <- [:throw, :exit] do
      test "reports #{kind}s" do
        handle_failure_event(unquote(kind), :foo, [])

        assert_sentry_report(:event,
          message: %{
            message: "Telemetry handler %s failed",
            formatted: "Telemetry handler my_handler failed"
          },
          tags: @tags,
          extra: %{kind: inspect(unquote(kind)), reason: ":foo"},
          exception: []
        )
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
