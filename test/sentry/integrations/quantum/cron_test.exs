defmodule Sentry.Integrations.Quantum.CronTest do
  use Sentry.Case, async: false

  alias Sentry.Integrations.CheckInIDMappings

  import Sentry.Test.Assertions

  alias Sentry.Test, as: SentryTest

  defmodule Scheduler do
    use Quantum, otp_app: :sentry
  end

  setup_all do
    Sentry.Integrations.Quantum.Cron.attach_telemetry_handler()
  end

  setup do
    SentryTest.setup_sentry(dedup_events: false, environment_name: "test")
  end

  for event_type <- [:start, :stop, :exception] do
    test "ignores #{event_type} events without a cron meta", %{bypass: bypass} do
      Bypass.down(bypass)

      :telemetry.execute([:quantum, :job, unquote(event_type)], %{}, %{
        job: Scheduler.new_job(name: :test_job)
      })
    end

    test "ignores #{event_type} events with a cron expr of @reboot", %{bypass: bypass} do
      Bypass.down(bypass)

      :telemetry.execute([:quantum, :job, unquote(event_type)], %{}, %{
        job:
          Scheduler.new_job(
            name: :reboot_job,
            schedule: Crontab.CronExpression.Parser.parse!("@reboot")
          )
      })
    end
  end

  test "captures start events with monitor config", %{bypass: bypass} do
    ref = SentryTest.setup_bypass_envelope_collector(bypass, type: "check_in")
    span_ref = make_ref()

    :telemetry.execute([:quantum, :job, :start], %{}, %{
      job:
        Scheduler.new_job(
          name: :test_job,
          schedule: Crontab.CronExpression.Parser.parse!("@daily")
        ),
      telemetry_span_context: span_ref
    })

    [check_in_body] = SentryTest.collect_sentry_check_ins(ref, 1)
    id = CheckInIDMappings.lookup_or_insert_new("quantum-#{:erlang.phash2(span_ref)}")

    assert_sentry_report(check_in_body,
      check_in_id: id,
      status: "in_progress",
      monitor_slug: "quantum-test-job",
      duration: nil,
      environment: "test",
      monitor_config: %{
        "schedule" => %{
          "type" => "crontab",
          "value" => "0 0 * * * *"
        },
        "timezone" => "Etc/UTC"
      }
    )
  end

  test "captures exception events with monitor config", %{bypass: bypass} do
    ref = SentryTest.setup_bypass_envelope_collector(bypass, type: "check_in")
    span_ref = make_ref()

    duration = System.convert_time_unit(12_099, :millisecond, :native)

    :telemetry.execute([:quantum, :job, :exception], %{duration: duration}, %{
      job:
        Scheduler.new_job(
          name: :test_job,
          schedule: Crontab.CronExpression.Parser.parse!("@daily"),
          timezone: "Europe/Rome"
        ),
      telemetry_span_context: span_ref
    })

    [check_in_body] = SentryTest.collect_sentry_check_ins(ref, 1)
    id = CheckInIDMappings.lookup_or_insert_new("quantum-#{:erlang.phash2(span_ref)}")

    assert_sentry_report(check_in_body,
      check_in_id: id,
      status: "error",
      monitor_slug: "quantum-test-job",
      duration: 12.099,
      environment: "test",
      monitor_config: %{
        "schedule" => %{
          "type" => "crontab",
          "value" => "0 0 * * * *"
        },
        "timezone" => "Europe/Rome"
      }
    )
  end

  test "captures stop events with monitor config", %{bypass: bypass} do
    ref = SentryTest.setup_bypass_envelope_collector(bypass, type: "check_in")
    span_ref = make_ref()

    duration = System.convert_time_unit(12_099, :millisecond, :native)

    :telemetry.execute([:quantum, :job, :stop], %{duration: duration}, %{
      job:
        Scheduler.new_job(
          name: :test_job,
          schedule: Crontab.CronExpression.Parser.parse!("@daily")
        ),
      telemetry_span_context: span_ref
    })

    [check_in_body] = SentryTest.collect_sentry_check_ins(ref, 1)
    id = CheckInIDMappings.lookup_or_insert_new("quantum-#{:erlang.phash2(span_ref)}")

    assert_sentry_report(check_in_body,
      check_in_id: id,
      status: "ok",
      monitor_slug: "quantum-test-job",
      duration: 12.099,
      environment: "test",
      monitor_config: %{
        "schedule" => %{
          "type" => "crontab",
          "value" => "0 0 * * * *"
        },
        "timezone" => "Etc/UTC"
      }
    )
  end

  for {job_name, expected_slug} <- [
        {:some_job, "quantum-some-job"},
        {MyApp.MyJob, "quantum-my-app-my-job"}
      ] do
    test "works for a job named #{inspect(job_name)}", %{bypass: bypass} do
      ref = SentryTest.setup_bypass_envelope_collector(bypass, type: "check_in")
      span_ref = make_ref()

      duration = System.convert_time_unit(12_099, :millisecond, :native)

      :telemetry.execute([:quantum, :job, :stop], %{duration: duration}, %{
        job:
          Scheduler.new_job(
            name: unquote(job_name),
            schedule: Crontab.CronExpression.Parser.parse!("@daily")
          ),
        telemetry_span_context: span_ref
      })

      [check_in_body] = SentryTest.collect_sentry_check_ins(ref, 1)
      assert_sentry_report(check_in_body, monitor_slug: unquote(expected_slug))
    end
  end

  test "works for a job without the name", %{bypass: bypass} do
    ref = SentryTest.setup_bypass_envelope_collector(bypass, type: "check_in")
    span_ref = make_ref()

    duration = System.convert_time_unit(12_099, :millisecond, :native)

    :telemetry.execute([:quantum, :job, :stop], %{duration: duration}, %{
      job: Scheduler.new_job(schedule: Crontab.CronExpression.Parser.parse!("@daily")),
      telemetry_span_context: span_ref
    })

    [check_in_body] = SentryTest.collect_sentry_check_ins(ref, 1)
    assert_sentry_report(check_in_body, monitor_slug: "quantum-generic-job")
  end

  test "start event and same ref stop event have same check-in id", %{bypass: bypass} do
    ref = SentryTest.setup_bypass_envelope_collector(bypass, type: "check_in")
    span_ref = make_ref()
    id = CheckInIDMappings.lookup_or_insert_new("quantum-#{:erlang.phash2(span_ref)}")

    :telemetry.execute([:quantum, :job, :start], %{}, %{
      job: Scheduler.new_job(schedule: Crontab.CronExpression.Parser.parse!("@daily")),
      telemetry_span_context: span_ref
    })

    duration = System.convert_time_unit(12_099, :millisecond, :native)

    :telemetry.execute([:quantum, :job, :stop], %{duration: duration}, %{
      job: Scheduler.new_job(schedule: Crontab.CronExpression.Parser.parse!("@daily")),
      telemetry_span_context: span_ref
    })

    [start_body, stop_body] = SentryTest.collect_sentry_check_ins(ref, 2)

    assert_sentry_report(start_body, check_in_id: id)
    assert_sentry_report(stop_body, check_in_id: id)
  end
end
