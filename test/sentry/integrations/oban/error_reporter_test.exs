defmodule Sentry.Integrations.Oban.ErrorReporterTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Sentry.Integrations.Oban.ErrorReporter

  defmodule MyWorker do
    use Oban.Worker

    @impl Oban.Worker
    def perform(%Oban.Job{}), do: :ok
  end

  @worker_as_string "Sentry.Integrations.Oban.ErrorReporterTest.MyWorker"

  describe "handle_event/4" do
    test "reports the correct error to Sentry" do
      Sentry.Test.start_collecting()

      emit_telemetry_for_failed_job(:error, %RuntimeError{message: "oops"}, [])

      assert [event] = Sentry.Test.pop_sentry_reports()
      assert event.original_exception == %RuntimeError{message: "oops"}
      assert [%{stacktrace: %{frames: [stacktrace]}} = exception] = event.exception

      assert exception.type == "RuntimeError"
      assert exception.value == "oops"
      assert exception.mechanism.handled == true
      assert stacktrace.module == MyWorker

      assert stacktrace.function ==
               "Sentry.Integrations.Oban.ErrorReporterTest.MyWorker.process/1"

      assert event.tags.oban_queue == "default"
      assert event.tags.oban_state == "available"
      assert event.tags.oban_worker == "Sentry.Integrations.Oban.ErrorReporterTest.MyWorker"
      assert %{job: %Oban.Job{}} = event.integration_meta.oban

      assert event.fingerprint == [@worker_as_string, "{{ default }}"]
    end

    test "unwraps Oban.PerformErrors and reports the wrapped error" do
      Sentry.Test.start_collecting()

      emit_telemetry_for_failed_job(
        :error,
        %Oban.PerformError{
          reason: {:error, %RuntimeError{message: "oops"}}
        },
        []
      )

      assert [event] = Sentry.Test.pop_sentry_reports()
      assert event.original_exception == %RuntimeError{message: "oops"}
      assert [%{stacktrace: %{frames: [stacktrace]}} = exception] = event.exception

      assert exception.type == "RuntimeError"
      assert exception.value == "oops"
      assert exception.mechanism.handled == true
      assert stacktrace.module == MyWorker

      assert stacktrace.function ==
               "Sentry.Integrations.Oban.ErrorReporterTest.MyWorker.process/1"

      assert event.tags.oban_queue == "default"
      assert event.tags.oban_state == "available"
      assert event.tags.oban_worker == "Sentry.Integrations.Oban.ErrorReporterTest.MyWorker"
      assert %{job: %Oban.Job{}} = event.integration_meta.oban

      assert event.fingerprint == [@worker_as_string, "{{ default }}"]
    end

    test "reports normalized non-exception errors to Sentry" do
      Sentry.Test.start_collecting()

      emit_telemetry_for_failed_job(:error, :undef, [])

      assert [event] = Sentry.Test.pop_sentry_reports()
      assert %{job: %Oban.Job{}} = event.integration_meta.oban

      assert event.message == nil

      assert [%{stacktrace: %{frames: [stacktrace]}} = exception] = event.exception

      assert exception.type == "UndefinedFunctionError"
      assert exception.value == "function #{@worker_as_string}.process/1 is undefined or private"
      assert exception.mechanism.handled == true
      assert stacktrace.module == MyWorker
      assert stacktrace.function == "#{@worker_as_string}.process/1"

      assert event.tags.oban_queue == "default"
      assert event.tags.oban_state == "available"
      assert event.tags.oban_worker == @worker_as_string

      assert event.fingerprint == [@worker_as_string, "{{ default }}"]
    end

    test "reports exits to Sentry" do
      Sentry.Test.start_collecting()

      emit_telemetry_for_failed_job(:exit, :oops, [])

      assert [event] = Sentry.Test.pop_sentry_reports()
      assert %{job: %Oban.Job{}} = event.integration_meta.oban

      assert event.message == %Sentry.Interfaces.Message{
               message: "Oban job #{@worker_as_string} exited: %s",
               params: [":oops"],
               formatted: "Oban job #{@worker_as_string} exited: :oops"
             }

      assert event.exception == []

      assert event.tags.oban_queue == "default"
      assert event.tags.oban_state == "available"
      assert event.tags.oban_worker == @worker_as_string

      assert event.fingerprint == [@worker_as_string, "{{ default }}"]
    end

    test "reports throws to Sentry" do
      Sentry.Test.start_collecting()

      emit_telemetry_for_failed_job(:throw, :this_was_not_caught, [])

      assert [event] = Sentry.Test.pop_sentry_reports()
      assert %{job: %Oban.Job{}} = event.integration_meta.oban

      assert event.message == %Sentry.Interfaces.Message{
               message: "Oban job #{@worker_as_string} exited with an uncaught throw: %s",
               params: [":this_was_not_caught"],
               formatted:
                 "Oban job #{@worker_as_string} exited with an uncaught throw: :this_was_not_caught"
             }

      assert event.exception == []

      assert event.tags.oban_queue == "default"
      assert event.tags.oban_state == "available"
      assert event.tags.oban_worker == @worker_as_string

      assert event.fingerprint == [@worker_as_string, "{{ default }}"]
    end

    for reason <- [:cancel, :discard] do
      test "doesn't report Oban.PerformError with reason #{inspect(reason)}" do
        Sentry.Test.start_collecting()

        emit_telemetry_for_failed_job(
          :error,
          %Oban.PerformError{reason: {unquote(reason), "nah"}},
          []
        )

        assert Sentry.Test.pop_sentry_reports() == []
      end
    end

    test "includes custom tags when oban_tags_to_sentry_tags function config option is set and returns non empty map" do
      Sentry.Test.start_collecting()

      emit_telemetry_for_failed_job(:error, %RuntimeError{message: "oops"}, [],
        oban_tags_to_sentry_tags: fn _job -> %{custom_tag: "custom_value"} end
      )

      assert [event] = Sentry.Test.pop_sentry_reports()
      assert event.tags.custom_tag == "custom_value"
    end

    test "handles oban_tags_to_sentry_tags errors gracefully" do
      Sentry.Test.start_collecting()

      emit_telemetry_for_failed_job(:error, %RuntimeError{message: "oops"}, [],
        oban_tags_to_sentry_tags: fn _job -> raise "tag transform error" end
      )

      assert [_event] = Sentry.Test.pop_sentry_reports()
    end

    test "handles invalid oban_tags_to_sentry_tags return values gracefully" do
      Sentry.Test.start_collecting()

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

        assert [_event] = Sentry.Test.pop_sentry_reports()
      end)
    end

    test "supports MFA tuple for oban_tags_to_sentry_tags" do
      defmodule TestTagsTransform do
        def transform(_job), do: %{custom_tag: "custom_value"}
      end

      Sentry.Test.start_collecting()

      emit_telemetry_for_failed_job(:error, %RuntimeError{message: "oops"}, [],
        oban_tags_to_sentry_tags: {TestTagsTransform, :transform}
      )

      assert [event] = Sentry.Test.pop_sentry_reports()
      assert event.tags.custom_tag == "custom_value"
    end

    test "skip_error_report_callback skips when callback returns true" do
      job =
        %{"id" => "123", "entity" => "user", "type" => "delete"}
        |> MyWorker.new()
        |> Ecto.Changeset.apply_action!(:validate)

      reason = %RuntimeError{message: "oops"}

      Sentry.Test.start_collecting()

      job_attempt_1 = Map.merge(job, %{attempt: 1, max_attempts: 3})

      # Callback returns true -> skip reporting
      assert :ok =
               ErrorReporter.handle_event(
                 [:oban, :job, :exception],
                 %{},
                 %{job: job_attempt_1, kind: :error, reason: reason, stacktrace: []},
                 skip_error_report_callback: fn _worker, job -> job.attempt < job.max_attempts end
               )

      assert [] = Sentry.Test.pop_sentry_reports()

      # Final attempt: callback returns false -> report
      job_attempt_3 = Map.merge(job, %{attempt: 3, max_attempts: 3})

      assert :ok =
               ErrorReporter.handle_event(
                 [:oban, :job, :exception],
                 %{},
                 %{job: job_attempt_3, kind: :error, reason: reason, stacktrace: []},
                 skip_error_report_callback: fn _worker, job -> job.attempt < job.max_attempts end
               )

      assert [event] = Sentry.Test.pop_sentry_reports()
      assert event.original_exception == %RuntimeError{message: "oops"}
      assert event.tags.oban_worker == "Sentry.Integrations.Oban.ErrorReporterTest.MyWorker"
    end

    test "skip_error_report_callback receives worker module and job" do
      job =
        %{"id" => "123", "entity" => "user", "type" => "delete"}
        |> MyWorker.new()
        |> Ecto.Changeset.apply_action!(:validate)

      reason = %RuntimeError{message: "oops"}
      test_pid = self()

      Sentry.Test.start_collecting()

      assert :ok =
               ErrorReporter.handle_event(
                 [:oban, :job, :exception],
                 %{},
                 %{job: job, kind: :error, reason: reason, stacktrace: []},
                 skip_error_report_callback: fn worker, received_job ->
                   send(test_pid, {:callback_args, worker, received_job})
                   false
                 end
               )

      assert_receive {:callback_args, worker, received_job}
      assert worker == MyWorker
      assert received_job == job
    end

    test "skip_error_report_callback reports when callback returns false" do
      Sentry.Test.start_collecting()

      emit_telemetry_for_failed_job(:error, %RuntimeError{message: "oops"}, [],
        skip_error_report_callback: fn _worker, _job -> false end
      )

      assert [event] = Sentry.Test.pop_sentry_reports()
      assert event.original_exception == %RuntimeError{message: "oops"}
    end

    test "skip_error_report_callback handles errors gracefully and defaults to reporting" do
      Sentry.Test.start_collecting()

      log =
        capture_log(fn ->
          emit_telemetry_for_failed_job(:error, %RuntimeError{message: "oops"}, [],
            skip_error_report_callback: fn _worker, _job -> raise "callback error" end
          )
        end)

      assert log =~ "skip_error_report_callback failed"
      assert log =~ "Sentry.Integrations.Oban.ErrorReporterTest.MyWorker"
      assert log =~ "callback error"

      assert [event] = Sentry.Test.pop_sentry_reports()
      assert event.original_exception == %RuntimeError{message: "oops"}
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
