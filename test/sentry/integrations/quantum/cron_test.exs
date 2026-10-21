defmodule Sentry.Integrations.Quantum.CronTest do
  use Sentry.Case, async: false

  alias Sentry.Integrations.CheckInIDMappings

  import ExUnit.CaptureLog
  import Sentry.Test.Assertions

  alias Sentry.Test, as: SentryTest

  defmodule Scheduler do
    use Quantum, otp_app: :sentry
  end

  setup_all do
    Sentry.Integrations.Quantum.Cron.attach_telemetry_handler()
  end

  setup do
    SentryTest.setup_sentry(
      dedup_events: false,
      environment_name: "test",
      collect_envelopes: [type: "check_in"]
    )
  end

  for event_type <- [:start, :stop, :exception] do
    test "ignores #{event_type} events without a cron meta", %{ref: ref} do
      :telemetry.execute([:quantum, :job, unquote(event_type)], %{}, %{
        job: Scheduler.new_job(name: :test_job)
      })

      refute_sentry_check_in(ref)
    end

    test "ignores #{event_type} events with a cron expr of @reboot", %{ref: ref} do
      :telemetry.execute([:quantum, :job, unquote(event_type)], %{}, %{
        job:
          Scheduler.new_job(
            name: :reboot_job,
            schedule: Crontab.CronExpression.Parser.parse!("@reboot")
          )
      })

      refute_sentry_check_in(ref)
    end
  end

  test "captures start events with monitor config", %{ref: ref} do
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

  test "captures exception events with monitor config", %{ref: ref} do
    span_ref = make_ref()
    id = CheckInIDMappings.lookup_or_insert_new("quantum-#{:erlang.phash2(span_ref)}")

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

  test "captures stop events with monitor config", %{ref: ref} do
    span_ref = make_ref()
    id = CheckInIDMappings.lookup_or_insert_new("quantum-#{:erlang.phash2(span_ref)}")

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
    test "works for a job named #{inspect(job_name)}", %{ref: ref} do
      span_ref = make_ref()
      _ = CheckInIDMappings.lookup_or_insert_new("quantum-#{:erlang.phash2(span_ref)}")

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

  test "works for a job without the name", %{ref: ref} do
    span_ref = make_ref()
    _ = CheckInIDMappings.lookup_or_insert_new("quantum-#{:erlang.phash2(span_ref)}")

    duration = System.convert_time_unit(12_099, :millisecond, :native)

    log =
      capture_log([metadata: [:domain]], fn ->
        :telemetry.execute([:quantum, :job, :stop], %{duration: duration}, %{
          job: Scheduler.new_job(schedule: Crontab.CronExpression.Parser.parse!("@daily")),
          telemetry_span_context: span_ref
        })
      end)

    assert log =~ "Sentry cannot report Quantum cron jobs correctly if they don't have a :name"
    assert log =~ ~r/domain=(\w+\.)*sentry/

    [check_in_body] = SentryTest.collect_sentry_check_ins(ref, 1)
    assert_sentry_report(check_in_body, monitor_slug: "quantum-generic-job")
  end

  test "start event and same ref stop event have same check-in id", %{ref: ref} do
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
    assert :ets.lookup(:sentry_cron_mappings, "quantum-#{:erlang.phash2(span_ref)}") == []
  end

  for event <- [:stop, :exception] do
    test "does not report a Quantum #{event} check-in after its id mapping expires", %{ref: ref} do
      span_ref = make_ref()
      cron_key = "quantum-#{:erlang.phash2(span_ref)}"

      job =
        Scheduler.new_job(
          name: :test_job,
          schedule: Crontab.CronExpression.Parser.parse!("@daily")
        )

      :telemetry.execute([:quantum, :job, :start], %{}, %{
        job: job,
        telemetry_span_context: span_ref
      })

      [start_body] = SentryTest.collect_sentry_check_ins(ref, 1)
      assert_sentry_report(start_body, status: "in_progress")

      expire_check_in_mapping!(cron_key)

      :telemetry.execute([:quantum, :job, unquote(event)], %{duration: 0}, %{
        job: job,
        telemetry_span_context: span_ref
      })

      refute_sentry_check_in(ref)
      assert :ets.lookup(:sentry_cron_mappings, cron_key) == []
    end
  end

  defp expire_check_in_mapping!(cron_key) do
    pid = Process.whereis(CheckInIDMappings)
    ttl = :sys.get_state(pid)

    case :ets.lookup(:sentry_cron_mappings, cron_key) do
      [{^cron_key, uuid, _inserted_at}] ->
        expired_at = System.system_time(:millisecond) - ttl - 1
        true = :ets.insert(:sentry_cron_mappings, {cron_key, uuid, expired_at})

      [] ->
        flunk("expected a check-in id mapping for #{inspect(cron_key)}")
    end

    send(pid, :sweep)
    _ = :sys.get_state(pid)
    assert :ets.lookup(:sentry_cron_mappings, cron_key) == []
  end
end
