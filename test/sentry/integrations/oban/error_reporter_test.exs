defmodule Sentry.Integrations.Oban.ErrorReporterTest do
  use ExUnit.Case, async: true

  alias Sentry.Integrations.Oban.ErrorReporter

  defmodule MyWorker do
    use Oban.Worker

    @impl Oban.Worker
    def perform(%Oban.Job{}), do: :ok
  end

  describe "handle_event/4" do
    test "reports the correct error to Sentry" do
      # Any worker is okay here, this is just an easier way to get a job struct.
      job =
        %{"id" => "123", "entity" => "user", "type" => "delete"}
        |> MyWorker.new()
        |> Ecto.Changeset.apply_action!(:validate)
        |> Map.replace!(:unsaved_error, %{
          reason: %RuntimeError{message: "oops"},
          kind: :error,
          stacktrace: []
        })

      Sentry.Test.start_collecting()

      assert :ok =
               ErrorReporter.handle_event(
                 [:oban, :job, :exception],
                 %{},
                 %{job: job},
                 :no_config
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
    end
  end
end
