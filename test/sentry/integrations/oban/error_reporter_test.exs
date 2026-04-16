defmodule Sentry.Integrations.Oban.ErrorReporterTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Sentry.Test.Assertions

  alias Sentry.Integrations.Oban.ErrorReporter
  alias Sentry.Test, as: SentryTest

  defmodule MyWorker do
    use Oban.Worker

    @impl Oban.Worker
    def perform(%Oban.Job{}), do: :ok
  end

  @worker_as_string "Sentry.Integrations.Oban.ErrorReporterTest.MyWorker"

  describe "handle_event/4" do
    setup do
      SentryTest.setup_sentry()
    end

    test "reports the correct error to Sentry" do
      emit_telemetry_for_failed_job(:error, %RuntimeError{message: "oops"}, [])

      event =
        assert_sentry_report(:event,
          tags: %{
            "oban_queue" => "default",
            "oban_state" => "available",
            "oban_worker" => @worker_as_string
          },
          fingerprint: [@worker_as_string, "{{ default }}"]
        )

      assert [exception] = event.exception
      assert exception.type == "RuntimeError"
      assert exception.value == "oops"
      assert exception.mechanism.handled == true
      assert [stacktrace] = exception.stacktrace.frames
      assert stacktrace.module == MyWorker
      assert stacktrace.function == "#{@worker_as_string}.process/1"
    end

    test "unwraps Oban.PerformErrors and reports the wrapped error" do
      emit_telemetry_for_failed_job(
        :error,
        %Oban.PerformError{
          reason: {:error, %RuntimeError{message: "oops"}}
        },
        []
      )

      event =
        assert_sentry_report(:event,
          tags: %{
            "oban_queue" => "default",
            "oban_state" => "available",
            "oban_worker" => @worker_as_string
          },
          fingerprint: [@worker_as_string, "{{ default }}"]
        )

      assert [exception] = event.exception
      assert exception.type == "RuntimeError"
      assert exception.value == "oops"
      assert exception.mechanism.handled == true
      assert [stacktrace] = exception.stacktrace.frames
      assert stacktrace.module == MyWorker
      assert stacktrace.function == "#{@worker_as_string}.process/1"
    end

    test "reports normalized non-exception errors to Sentry" do
      emit_telemetry_for_failed_job(:error, :undef, [])

      event =
        assert_sentry_report(:event,
          message: nil,
          tags: %{
            "oban_queue" => "default",
            "oban_state" => "available",
            "oban_worker" => @worker_as_string
          },
          fingerprint: [@worker_as_string, "{{ default }}"]
        )

      assert [exception] = event.exception
      assert exception.type == "UndefinedFunctionError"

      assert exception.value ==
               "function #{@worker_as_string}.process/1 is undefined or private"

      assert exception.mechanism.handled == true
      assert [stacktrace] = exception.stacktrace.frames
      assert stacktrace.module == MyWorker
      assert stacktrace.function == "#{@worker_as_string}.process/1"
    end

    test "reports exits to Sentry" do
      emit_telemetry_for_failed_job(:exit, :oops, [])

      assert_sentry_report(:event,
        message: %{
          message: "Oban job #{@worker_as_string} exited: %s",
          params: [":oops"],
          formatted: "Oban job #{@worker_as_string} exited: :oops"
        },
        exception: [],
        tags: %{
          "oban_queue" => "default",
          "oban_state" => "available",
          "oban_worker" => @worker_as_string
        },
        fingerprint: [@worker_as_string, "{{ default }}"]
      )
    end

    test "reports throws to Sentry" do
      emit_telemetry_for_failed_job(:throw, :this_was_not_caught, [])

      assert_sentry_report(:event,
        message: %{
          message: "Oban job #{@worker_as_string} exited with an uncaught throw: %s",
          params: [":this_was_not_caught"],
          formatted:
            "Oban job #{@worker_as_string} exited with an uncaught throw: :this_was_not_caught"
        },
        exception: [],
        tags: %{
          "oban_queue" => "default",
          "oban_state" => "available",
          "oban_worker" => @worker_as_string
        },
        fingerprint: [@worker_as_string, "{{ default }}"]
      )
    end

    for reason <- [:cancel, :discard] do
      test "doesn't report Oban.PerformError with reason #{inspect(reason)}" do
        emit_telemetry_for_failed_job(
          :error,
          %Oban.PerformError{reason: {unquote(reason), "nah"}},
          []
        )

        assert [] = SentryTest.pop_sentry_reports()
      end
    end

    test "includes custom tags when oban_tags_to_sentry_tags function config option is set and returns non empty map" do
      emit_telemetry_for_failed_job(:error, %RuntimeError{message: "oops"}, [],
        oban_tags_to_sentry_tags: fn _job -> %{custom_tag: "custom_value"} end
      )

      assert_sentry_report(:event, tags: %{"custom_tag" => "custom_value"})
    end

    test "handles oban_tags_to_sentry_tags errors gracefully" do
      emit_telemetry_for_failed_job(:error, %RuntimeError{message: "oops"}, [],
        oban_tags_to_sentry_tags: fn _job -> raise "tag transform error" end
      )

      assert_sentry_report(:event, [])
    end

    test "handles invalid oban_tags_to_sentry_tags return values gracefully" do
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

      events = SentryTest.pop_sentry_reports()
      assert length(events) == length(test_cases)
    end

    test "supports MFA tuple for oban_tags_to_sentry_tags" do
      defmodule TestTagsTransform do
        def transform(_job), do: %{custom_tag: "custom_value"}
      end

      emit_telemetry_for_failed_job(:error, %RuntimeError{message: "oops"}, [],
        oban_tags_to_sentry_tags: {TestTagsTransform, :transform}
      )

      assert_sentry_report(:event, tags: %{"custom_tag" => "custom_value"})
    end

    test "should_report_error_callback skips when callback returns false" do
      job =
        %{"id" => "123", "entity" => "user", "type" => "delete"}
        |> MyWorker.new()
        |> Ecto.Changeset.apply_action!(:validate)

      reason = %RuntimeError{message: "oops"}

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

      assert [] = SentryTest.pop_sentry_reports()

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

      event = assert_sentry_report(:event, tags: %{"oban_worker" => @worker_as_string})
      assert [exception] = event.exception
      assert exception.type == "RuntimeError"
    end

    test "should_report_error_callback receives worker module and job" do
      job =
        %{"id" => "123", "entity" => "user", "type" => "delete"}
        |> MyWorker.new()
        |> Ecto.Changeset.apply_action!(:validate)

      reason = %RuntimeError{message: "oops"}
      test_pid = self()

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

    test "should_report_error_callback reports when callback returns true" do
      emit_telemetry_for_failed_job(:error, %RuntimeError{message: "oops"}, [],
        should_report_error_callback: fn _worker, _job -> true end
      )

      event = assert_sentry_report(:event, [])
      assert [exception] = event.exception
      assert exception.type == "RuntimeError"
      assert exception.value == "oops"
    end

    test "should_report_error_callback handles errors gracefully and defaults to reporting" do
      log =
        capture_log(fn ->
          emit_telemetry_for_failed_job(:error, %RuntimeError{message: "oops"}, [],
            should_report_error_callback: fn _worker, _job -> raise "callback error" end
          )
        end)

      assert log =~ "should_report_error_callback failed"
      assert log =~ "Sentry.Integrations.Oban.ErrorReporterTest.MyWorker"
      assert log =~ "callback error"

      event = assert_sentry_report(:event, [])
      assert [exception] = event.exception
      assert exception.type == "RuntimeError"
      assert exception.value == "oops"
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
