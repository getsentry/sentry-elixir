defmodule Sentry.Integrations.Oban.ErrorReporterTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Sentry.TestHelpers

  alias Sentry.Integrations.Oban.ErrorReporter

  defmodule MyWorker do
    use Oban.Worker

    @impl Oban.Worker
    def perform(%Oban.Job{}), do: :ok
  end

  @worker_as_string "Sentry.Integrations.Oban.ErrorReporterTest.MyWorker"

  describe "handle_event/4" do
    setup do
      setup_bypass()
    end

    test "reports the correct error to Sentry", %{bypass: bypass} do
      ref = setup_bypass_envelope_collector(bypass, type: "event")

      emit_telemetry_for_failed_job(:error, %RuntimeError{message: "oops"}, [])

      assert [event] = collect_envelopes(ref, 1) |> extract_events()
      assert [%{"stacktrace" => %{"frames" => [stacktrace]}} = exception] = event["exception"]

      assert exception["type"] == "RuntimeError"
      assert exception["value"] == "oops"
      assert exception["mechanism"]["handled"] == true
      assert stacktrace["module"] == "Elixir.Sentry.Integrations.Oban.ErrorReporterTest.MyWorker"

      assert stacktrace["function"] ==
               "Sentry.Integrations.Oban.ErrorReporterTest.MyWorker.process/1"

      assert event["tags"]["oban_queue"] == "default"
      assert event["tags"]["oban_state"] == "available"
      assert event["tags"]["oban_worker"] == "Sentry.Integrations.Oban.ErrorReporterTest.MyWorker"

      assert event["fingerprint"] == [@worker_as_string, "{{ default }}"]
    end

    test "unwraps Oban.PerformErrors and reports the wrapped error", %{bypass: bypass} do
      ref = setup_bypass_envelope_collector(bypass, type: "event")

      emit_telemetry_for_failed_job(
        :error,
        %Oban.PerformError{
          reason: {:error, %RuntimeError{message: "oops"}}
        },
        []
      )

      assert [event] = collect_envelopes(ref, 1) |> extract_events()
      assert [%{"stacktrace" => %{"frames" => [stacktrace]}} = exception] = event["exception"]

      assert exception["type"] == "RuntimeError"
      assert exception["value"] == "oops"
      assert exception["mechanism"]["handled"] == true
      assert stacktrace["module"] == "Elixir.Sentry.Integrations.Oban.ErrorReporterTest.MyWorker"

      assert stacktrace["function"] ==
               "Sentry.Integrations.Oban.ErrorReporterTest.MyWorker.process/1"

      assert event["tags"]["oban_queue"] == "default"
      assert event["tags"]["oban_state"] == "available"
      assert event["tags"]["oban_worker"] == "Sentry.Integrations.Oban.ErrorReporterTest.MyWorker"

      assert event["fingerprint"] == [@worker_as_string, "{{ default }}"]
    end

    test "reports normalized non-exception errors to Sentry", %{bypass: bypass} do
      ref = setup_bypass_envelope_collector(bypass, type: "event")

      emit_telemetry_for_failed_job(:error, :undef, [])

      assert [event] = collect_envelopes(ref, 1) |> extract_events()

      assert event["message"] == nil

      assert [%{"stacktrace" => %{"frames" => [stacktrace]}} = exception] = event["exception"]

      assert exception["type"] == "UndefinedFunctionError"

      assert exception["value"] ==
               "function #{@worker_as_string}.process/1 is undefined or private"

      assert exception["mechanism"]["handled"] == true
      assert stacktrace["module"] == "Elixir.Sentry.Integrations.Oban.ErrorReporterTest.MyWorker"
      assert stacktrace["function"] == "#{@worker_as_string}.process/1"

      assert event["tags"]["oban_queue"] == "default"
      assert event["tags"]["oban_state"] == "available"
      assert event["tags"]["oban_worker"] == @worker_as_string

      assert event["fingerprint"] == [@worker_as_string, "{{ default }}"]
    end

    test "reports exits to Sentry", %{bypass: bypass} do
      ref = setup_bypass_envelope_collector(bypass, type: "event")

      emit_telemetry_for_failed_job(:exit, :oops, [])

      assert [event] = collect_envelopes(ref, 1) |> extract_events()

      assert event["message"]["message"] == "Oban job #{@worker_as_string} exited: %s"
      assert event["message"]["params"] == [":oops"]
      assert event["message"]["formatted"] == "Oban job #{@worker_as_string} exited: :oops"

      assert event["exception"] == []

      assert event["tags"]["oban_queue"] == "default"
      assert event["tags"]["oban_state"] == "available"
      assert event["tags"]["oban_worker"] == @worker_as_string

      assert event["fingerprint"] == [@worker_as_string, "{{ default }}"]
    end

    test "reports throws to Sentry", %{bypass: bypass} do
      ref = setup_bypass_envelope_collector(bypass, type: "event")

      emit_telemetry_for_failed_job(:throw, :this_was_not_caught, [])

      assert [event] = collect_envelopes(ref, 1) |> extract_events()

      assert event["message"]["message"] ==
               "Oban job #{@worker_as_string} exited with an uncaught throw: %s"

      assert event["message"]["params"] == [":this_was_not_caught"]

      assert event["message"]["formatted"] ==
               "Oban job #{@worker_as_string} exited with an uncaught throw: :this_was_not_caught"

      assert event["exception"] == []

      assert event["tags"]["oban_queue"] == "default"
      assert event["tags"]["oban_state"] == "available"
      assert event["tags"]["oban_worker"] == @worker_as_string

      assert event["fingerprint"] == [@worker_as_string, "{{ default }}"]
    end

    for reason <- [:cancel, :discard] do
      test "doesn't report Oban.PerformError with reason #{inspect(reason)}", %{bypass: bypass} do
        test_pid = self()

        Bypass.stub(bypass, "POST", "/api/1/envelope/", fn conn ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)

          # Only flag error events as unexpected. Stray transaction envelopes
          # from background processes (e.g., OpenTelemetry span processor) may
          # arrive due to concurrent persistent_term DSN writes in async tests.
          if body =~ ~r/"type":\s*"event"/ do
            send(test_pid, :unexpected_envelope)
          end

          Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
        end)

        emit_telemetry_for_failed_job(
          :error,
          %Oban.PerformError{reason: {unquote(reason), "nah"}},
          []
        )

        refute_receive :unexpected_envelope, 100
      end
    end

    test "includes custom tags when oban_tags_to_sentry_tags function config option is set and returns non empty map",
         %{bypass: bypass} do
      ref = setup_bypass_envelope_collector(bypass, type: "event")

      emit_telemetry_for_failed_job(:error, %RuntimeError{message: "oops"}, [],
        oban_tags_to_sentry_tags: fn _job -> %{custom_tag: "custom_value"} end
      )

      assert [event] = collect_envelopes(ref, 1) |> extract_events()
      assert event["tags"]["custom_tag"] == "custom_value"
    end

    test "handles oban_tags_to_sentry_tags errors gracefully", %{bypass: bypass} do
      ref = setup_bypass_envelope_collector(bypass, type: "event")

      emit_telemetry_for_failed_job(:error, %RuntimeError{message: "oops"}, [],
        oban_tags_to_sentry_tags: fn _job -> raise "tag transform error" end
      )

      assert [_event] = collect_envelopes(ref, 1) |> extract_events()
    end

    test "handles invalid oban_tags_to_sentry_tags return values gracefully", %{bypass: bypass} do
      ref = setup_bypass_envelope_collector(bypass, type: "event")

      test_cases = [
        1,
        "invalid",
        :invalid,
        [1, 2, 3],
        nil
      ]

      Enum.each(test_cases, fn invalid_value ->
        emit_telemetry_for_failed_job(:error, %RuntimeError{message: "oops"}, [],
          oban_tags_to_sentry_tags: fn _job -> invalid_value end
        )
      end)

      events = collect_envelopes(ref, length(test_cases)) |> extract_events()
      assert length(events) == length(test_cases)
    end

    test "supports MFA tuple for oban_tags_to_sentry_tags", %{bypass: bypass} do
      defmodule TestTagsTransform do
        def transform(_job), do: %{custom_tag: "custom_value"}
      end

      ref = setup_bypass_envelope_collector(bypass, type: "event")

      emit_telemetry_for_failed_job(:error, %RuntimeError{message: "oops"}, [],
        oban_tags_to_sentry_tags: {TestTagsTransform, :transform}
      )

      assert [event] = collect_envelopes(ref, 1) |> extract_events()
      assert event["tags"]["custom_tag"] == "custom_value"
    end

    test "should_report_error_callback skips when callback returns false", %{bypass: bypass} do
      job =
        %{"id" => "123", "entity" => "user", "type" => "delete"}
        |> MyWorker.new()
        |> Ecto.Changeset.apply_action!(:validate)

      reason = %RuntimeError{message: "oops"}
      test_pid = self()

      Bypass.stub(bypass, "POST", "/api/1/envelope/", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        # Only forward error events. Stray transaction envelopes from
        # background processes may arrive in async tests.
        if body =~ ~r/"type":\s*"event"/ do
          send(test_pid, {:envelope, body})
        end

        Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
      end)

      job_attempt_1 = Map.merge(job, %{attempt: 1, max_attempts: 3})

      # Callback returns false -> skip reporting
      assert :ok =
               ErrorReporter.handle_event(
                 [:oban, :job, :exception],
                 %{},
                 %{job: job_attempt_1, kind: :error, reason: reason, stacktrace: []},
                 should_report_error_callback: fn _worker, job ->
                   job.attempt >= job.max_attempts
                 end
               )

      refute_receive {:envelope, _}, 100

      # Final attempt: callback returns true -> report
      job_attempt_3 = Map.merge(job, %{attempt: 3, max_attempts: 3})

      assert :ok =
               ErrorReporter.handle_event(
                 [:oban, :job, :exception],
                 %{},
                 %{job: job_attempt_3, kind: :error, reason: reason, stacktrace: []},
                 should_report_error_callback: fn _worker, job ->
                   job.attempt >= job.max_attempts
                 end
               )

      assert_receive {:envelope, body}
      assert [event] = decode_envelope!(body) |> Enum.map(&elem(&1, 1))
      assert [exception] = event["exception"]
      assert exception["type"] == "RuntimeError"
      assert event["tags"]["oban_worker"] == "Sentry.Integrations.Oban.ErrorReporterTest.MyWorker"
    end

    test "should_report_error_callback receives worker module and job", %{bypass: bypass} do
      job =
        %{"id" => "123", "entity" => "user", "type" => "delete"}
        |> MyWorker.new()
        |> Ecto.Changeset.apply_action!(:validate)

      reason = %RuntimeError{message: "oops"}
      test_pid = self()

      Bypass.stub(bypass, "POST", "/api/1/envelope/", fn conn ->
        Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
      end)

      assert :ok =
               ErrorReporter.handle_event(
                 [:oban, :job, :exception],
                 %{},
                 %{job: job, kind: :error, reason: reason, stacktrace: []},
                 should_report_error_callback: fn worker, received_job ->
                   send(test_pid, {:callback_args, worker, received_job})
                   true
                 end
               )

      assert_receive {:callback_args, worker, received_job}
      assert worker == MyWorker
      assert received_job == job
    end

    test "should_report_error_callback reports when callback returns true", %{bypass: bypass} do
      ref = setup_bypass_envelope_collector(bypass, type: "event")

      emit_telemetry_for_failed_job(:error, %RuntimeError{message: "oops"}, [],
        should_report_error_callback: fn _worker, _job -> true end
      )

      assert [event] = collect_envelopes(ref, 1) |> extract_events()
      assert [exception] = event["exception"]
      assert exception["type"] == "RuntimeError"
      assert exception["value"] == "oops"
    end

    test "should_report_error_callback handles errors gracefully and defaults to reporting",
         %{bypass: bypass} do
      ref = setup_bypass_envelope_collector(bypass, type: "event")

      log =
        capture_log(fn ->
          emit_telemetry_for_failed_job(:error, %RuntimeError{message: "oops"}, [],
            should_report_error_callback: fn _worker, _job -> raise "callback error" end
          )
        end)

      assert log =~ "should_report_error_callback failed"
      assert log =~ "Sentry.Integrations.Oban.ErrorReporterTest.MyWorker"
      assert log =~ "callback error"

      assert [event] = collect_envelopes(ref, 1) |> extract_events()
      assert [exception] = event["exception"]
      assert exception["type"] == "RuntimeError"
      assert exception["value"] == "oops"
    end
  end

  ## Helpers

  defp emit_telemetry_for_failed_job(kind, reason, stacktrace, config \\ []) do
    job =
      %{"id" => "123", "entity" => "user", "type" => "delete"}
      |> MyWorker.new()
      |> Ecto.Changeset.apply_action!(:validate)

    assert :ok =
             ErrorReporter.handle_event(
               [:oban, :job, :exception],
               %{},
               %{job: job, kind: kind, reason: reason, stacktrace: stacktrace},
               config
             )

    job
  end
end
