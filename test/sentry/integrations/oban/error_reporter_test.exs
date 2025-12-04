defmodule Sentry.Integrations.Oban.ErrorReporterTest do
  use ExUnit.Case, async: true

  alias Sentry.Integrations.Oban.ErrorReporter

  defmodule MyWorker do
    use Oban.Worker, tags: ["tag1", "tag2"]

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
      assert event.tags.oban_tags == "tag1,tag2"
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
      assert event.tags.oban_tags == "tag1,tag2"
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

    test "includes oban_tags when config option is enabled" do
      Sentry.Test.start_collecting()

      emit_telemetry_for_failed_job(:error, %RuntimeError{message: "oops"}, [], oban_tags: true)

      assert [event] = Sentry.Test.pop_sentry_reports()
      assert event.tags.oban_tags == "tag1,tag2"
    end

    test "excludes oban_tags when config option is disabled" do
      Sentry.Test.start_collecting()

      emit_telemetry_for_failed_job(:error, %RuntimeError{message: "oops"}, [], oban_tags: false)

      assert [event] = Sentry.Test.pop_sentry_reports()
      assert is_nil(Map.get(event.tags, :oban_tags))
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
