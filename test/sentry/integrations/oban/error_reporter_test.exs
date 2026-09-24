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

    test "reports exits with a non-list stacktrace without crashing" do
      # When a job dies from a gen-call exit (e.g. a GenServer.call or a
      # NimblePool/Finch checkout timeout), Oban surfaces the {module, function,
      # args} from the exit reason in the :stacktrace metadata, which is not a
      # list. The reporter must not pass that straight to Sentry's :stacktrace
      # option, since it would crash and get the telemetry handler detached.
      emit_telemetry_for_failed_job(
        :exit,
        {:shutdown, :idle_timeout},
        {NimblePool, :checkout, [self()]}
      )

      assert_sentry_report(:event,
        message: %{
          message: "Oban job #{@worker_as_string} exited: %s",
          params: ["{:shutdown, :idle_timeout}"],
          formatted: "Oban job #{@worker_as_string} exited: {:shutdown, :idle_timeout}"
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

    for {kind, failure} <- [
          raise: quote(do: raise("tag transform error")),
          throw: quote(do: throw(:tag_transform_error)),
          exit: quote(do: exit(:tag_transform_error))
        ] do
      test "falls back to the base Oban tags when oban_tags_to_sentry_tags #{kind}s" do
        log =
          capture_log([metadata: [:domain]], fn ->
            emit_telemetry_for_failed_job(:error, %RuntimeError{message: "oops"}, [],
              oban_tags_to_sentry_tags: fn _job -> unquote(failure) end
            )
          end)

        assert log =~ ~r/domain=(\w+\.)*sentry \[error\]/

        assert log =~
                 ":oban_tags_to_sentry_tags callback failed " <>
                   "for worker #{inspect(@worker_as_string)} (job ID nil)"

        assert_sentry_report(:event,
          tags: %{
            "oban_queue" => "default",
            "oban_state" => "available",
            "oban_worker" => @worker_as_string
          }
        )
      end
    end

    test "handles invalid oban_tags_to_sentry_tags return values gracefully" do
      test_cases = [
        1,
        "invalid",
        :invalid,
        [1, 2, 3],
        nil
      ]

      log =
        capture_log([metadata: [:domain]], fn ->
          Enum.each(test_cases, fn invalid_value ->
            emit_telemetry_for_failed_job(:error, %RuntimeError{message: "oops"}, [],
              oban_tags_to_sentry_tags: fn _job -> invalid_value end
            )
          end)
        end)

      assert log =~ ":oban_tags_to_sentry_tags callback returned an invalid value: expected a map"
      assert log =~ ~r/domain=(\w+\.)*sentry \[warning\]/

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

    for {kind, failure} <- [
          raise: quote(do: raise("callback error")),
          throw: quote(do: throw(:callback_error)),
          exit: quote(do: exit(:callback_error))
        ] do
      test "should_report_error_callback still reports the error when it #{kind}s" do
        log =
          capture_log([metadata: [:domain]], fn ->
            emit_telemetry_for_failed_job(:error, %RuntimeError{message: "oops"}, [],
              should_report_error_callback: fn _worker, _job -> unquote(failure) end
            )
          end)

        assert log =~ ~r/domain=(\w+\.)*sentry \[error\]/

        assert log =~
                 ":should_report_error_callback callback failed " <>
                   "for worker #{@worker_as_string} (job ID nil)"

        event = assert_sentry_report(:event, [])
        assert [exception] = event.exception
        assert exception.type == "RuntimeError"
        assert exception.value == "oops"
      end
    end

    test "should_report_error_callback receives a nil worker when the job worker doesn't resolve" do
      test_pid = self()

      job =
        %{"id" => "123"}
        |> MyWorker.new()
        |> Ecto.Changeset.apply_action!(:validate)
        |> Map.put(:worker, "NotA.Real.Worker")

      log =
        capture_log([metadata: [:domain]], fn ->
          assert :ok =
                   ErrorReporter.handle_event(
                     [:oban, :job, :exception],
                     %{},
                     %{
                       job: job,
                       kind: :error,
                       reason: %RuntimeError{message: "oops"},
                       stacktrace: []
                     },
                     should_report_error_callback: fn worker, _job ->
                       send(test_pid, {:callback_worker, worker})
                       true
                     end
                   )
        end)

      assert log =~ ~s(Could not resolve Oban worker module from string: "NotA.Real.Worker")
      assert log =~ ~r/domain=(\w+\.)*sentry/

      assert_receive {:callback_worker, nil}
      assert_sentry_report(:event, [])
    end

    test "scrubs sensitive values from the job args in the event extra" do
      emit_telemetry_for_failed_job(
        :error,
        %RuntimeError{message: "oops"},
        [],
        [],
        %{"id" => "123", "password" => "hunter2", "entity" => "user"}
      )

      event = assert_sentry_report(:event, fingerprint: [@worker_as_string, "{{ default }}"])

      assert event.extra[:args]["password"] == "[Filtered]"
      assert event.extra[:args]["id"] == "123"
      assert event.extra[:args]["entity"] == "user"
    end
  end

  describe "when handling a job event fails" do
    setup do
      SentryTest.setup_sentry()
    end

    for {kind, failure} <- [
          raise: quote(do: raise("the callback is broken")),
          throw: quote(do: throw(:the_callback_is_broken)),
          exit: quote(do: exit(:the_callback_is_broken))
        ] do
      test "keeps reporting job exceptions after a callback #{kind}s" do
        attach_error_reporter(
          should_report_error_callback: fn _worker, job ->
            if job.args["id"] == "broken", do: unquote(failure), else: true
          end
        )

        capture_log(fn ->
          execute_exception_event(build_job(%{"id" => "broken"}), %RuntimeError{
            message: "broken job"
          })

          execute_exception_event(build_job(%{"id" => "later"}), %RuntimeError{
            message: "later job"
          })
        end)

        assert handler_attached?()
        assert "later job" in reported_exception_values()
      end
    end

    test "records a discarded error when the job event carries no exception", %{
      client_report_sender: sender
    } do
      attach_error_reporter()

      log =
        capture_log([metadata: [:domain]], fn ->
          :telemetry.execute([:oban, :job, :exception], %{}, %{job: build_job()})
        end)

      assert log =~
               ~r/domain=(\w+\.)*sentry \[error\]\s+Sentry failed to report an Oban job exception/

      assert handler_attached?()
      assert [] = SentryTest.pop_sentry_reports()
      assert %{{:internal_sdk_error, "error"} => 1} = :sys.get_state(sender)
    end
  end

  ## Helpers

  defp attach_error_reporter(config \\ []) do
    :ok = ErrorReporter.attach(config)
    on_exit(fn -> :telemetry.detach(ErrorReporter) end)
  end

  defp handler_attached? do
    [:oban, :job, :exception]
    |> :telemetry.list_handlers()
    |> Enum.any?(&(&1.id == ErrorReporter))
  end

  defp execute_exception_event(job, reason) do
    :telemetry.execute([:oban, :job, :exception], %{}, %{
      job: job,
      kind: :error,
      reason: reason,
      stacktrace: []
    })
  end

  defp build_job(args \\ %{"id" => "123"}) do
    args
    |> MyWorker.new()
    |> Ecto.Changeset.apply_action!(:validate)
  end

  defp reported_exception_values do
    for event <- SentryTest.pop_sentry_reports(),
        exception <- event.exception,
        do: exception.value
  end

  defp emit_telemetry_for_failed_job(
         kind,
         reason,
         stacktrace,
         config \\ [],
         args \\ %{"id" => "123", "entity" => "user", "type" => "delete"}
       ) do
    job =
      args
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
