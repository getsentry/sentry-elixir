defmodule Sentry.Integrations.TelemetryTest do
  use ExUnit.Case, async: true

  alias Sentry.Integrations.Telemetry

  describe "handle_event/4" do
    test "reports errors" do
      Sentry.Test.start_collecting()

      handle_failure_event(:error, %RuntimeError{message: "oops"}, [])

      assert [event] = Sentry.Test.pop_sentry_reports()

      assert event.tags == %{
               telemetry_handler_id: "my_handler",
               event_name: "[:my_app, :some_event]"
             }

      assert event.original_exception == %RuntimeError{message: "oops"}
    end

    test "reports Erlang errors (normalized)" do
      Sentry.Test.start_collecting()

      handle_failure_event(:error, {:badmap, :foo}, [])

      assert [event] = Sentry.Test.pop_sentry_reports()

      assert event.tags == %{
               telemetry_handler_id: "my_handler",
               event_name: "[:my_app, :some_event]"
             }

      assert event.original_exception == %BadMapError{term: :foo}
    end

    for kind <- [:throw, :exit] do
      test "reports #{kind}s" do
        Sentry.Test.start_collecting()

        handle_failure_event(unquote(kind), :foo, [])

        assert [event] = Sentry.Test.pop_sentry_reports()

        assert event.message.message == "Telemetry handler %s failed"
        assert event.message.formatted == ~s(Telemetry handler "my_handler" failed)

        assert event.tags == %{
                 telemetry_handler_id: "my_handler",
                 event_name: "[:my_app, :some_event]"
               }

        assert event.extra == %{kind: inspect(unquote(kind)), reason: ":foo"}

        assert event.original_exception == nil
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
