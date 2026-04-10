defmodule Sentry.Integrations.Oban.CronTest do
  alias Sentry.Integrations.CheckInIDMappings
  use Sentry.Case, async: false

  import Sentry.Test.Assertions
  import Sentry.TestHelpers

  alias Sentry.Test, as: SentryTest

  setup context do
    opts = context[:attach_opts] || []

    Sentry.Integrations.Oban.Cron.attach_telemetry_handler(opts)
    on_exit(fn -> :telemetry.detach(Sentry.Integrations.Oban.Cron) end)
  end

  setup do
    SentryTest.setup_sentry(dedup_events: false, environment_name: "test")
  end

  for event_type <- [:start, :stop, :exception] do
    test "ignores #{event_type} events without a cron meta", %{bypass: bypass} do
      Bypass.down(bypass)
      :telemetry.execute([:oban, :job, unquote(event_type)], %{}, %{job: %Oban.Job{}})
    end

    test "ignores #{event_type} events without a cron_expr meta", %{bypass: bypass} do
      Bypass.down(bypass)

      :telemetry.execute([:oban, :job, unquote(event_type)], %{}, %{
        job: %Oban.Job{meta: %{"cron" => true}}
      })
    end

    test "ignores #{event_type} events with a cron expr of @reboot", %{bypass: bypass} do
      Bypass.down(bypass)

      :telemetry.execute([:oban, :job, unquote(event_type)], %{}, %{
        job: %Oban.Job{
          worker: "Sentry.MyWorker",
          meta: %{"cron" => true, "cron_expr" => "@reboot"}
        }
      })
    end

    test "ignores #{event_type} events with a cron expr of @reboot even with timezone", %{
      bypass: bypass
    } do
      Bypass.down(bypass)

      :telemetry.execute([:oban, :job, unquote(event_type)], %{}, %{
        job: %Oban.Job{
          worker: "Sentry.MyWorker",
          meta: %{"cron" => true, "cron_expr" => "@reboot", "cron_tz" => "Etc/UTC"}
        }
      })
    end

    test "ignores #{event_type} events with a cron expr that is not a string", %{bypass: bypass} do
      Bypass.down(bypass)

      :telemetry.execute([:oban, :job, unquote(event_type)], %{}, %{
        job: %Oban.Job{worker: "Sentry.MyWorker", meta: %{"cron" => true, "cron_expr" => 123}}
      })
    end
  end

  test "captures start events with monitor config", %{bypass: bypass} do
    ref = SentryTest.setup_bypass_envelope_collector(bypass, type: "check_in")

    :telemetry.execute([:oban, :job, :start], %{}, %{
      job: %Oban.Job{
        worker: "Sentry.MyWorker",
        id: 123,
        meta: %{"cron" => true, "cron_expr" => "@daily"}
      }
    })

    assert [[{headers, check_in_body}]] = SentryTest.collect_envelopes(ref, 1)
    id = CheckInIDMappings.lookup_or_insert_new(123)

    assert headers["type"] == "check_in"

    assert_sentry_report(check_in_body,
      check_in_id: id,
      status: "in_progress",
      monitor_slug: "sentry-my-worker",
      duration: nil,
      environment: "test",
      monitor_config: %{
        "schedule" => %{
          "type" => "interval",
          "value" => 1,
          "unit" => "day"
        }
      }
    )
  end

  for {oban_state, expected_status} <- [
        success: "ok",
        failure: "error",
        cancelled: "ok",
        discard: "ok",
        snoozed: "ok"
      ],
      {frequency, expected_unit} <- [
        {"@hourly", "hour"},
        {"@daily", "day"},
        {"@weekly", "week"},
        {"@monthly", "month"},
        {"@yearly", "year"},
        {"@annually", "year"}
      ] do
    test "captures stop events with monitor config and state of #{inspect(oban_state)} and frequency of #{frequency}",
         %{bypass: bypass} do
      ref = SentryTest.setup_bypass_envelope_collector(bypass, type: "check_in")

      duration = System.convert_time_unit(12_099, :millisecond, :native)

      :telemetry.execute([:oban, :job, :stop], %{duration: duration}, %{
        state: unquote(oban_state),
        job: %Oban.Job{
          worker: "Sentry.MyWorker",
          id: 942,
          meta: %{"cron" => true, "cron_expr" => unquote(frequency), "cron_tz" => "Europe/Rome"}
        }
      })

      assert [[{headers, check_in_body}]] = SentryTest.collect_envelopes(ref, 1)
      id = CheckInIDMappings.lookup_or_insert_new(942)

      assert headers["type"] == "check_in"

      assert_sentry_report(check_in_body,
        check_in_id: id,
        status: unquote(expected_status),
        monitor_slug: "sentry-my-worker",
        duration: 12.099,
        environment: "test",
        monitor_config: %{
          "schedule" => %{
            "type" => "interval",
            "value" => 1,
            "unit" => unquote(expected_unit)
          },
          "timezone" => "Europe/Rome"
        }
      )
    end
  end

  test "captures exception events with monitor config", %{bypass: bypass} do
    ref = SentryTest.setup_bypass_envelope_collector(bypass, type: "check_in")

    duration = System.convert_time_unit(12_099, :millisecond, :native)

    :telemetry.execute([:oban, :job, :exception], %{duration: duration}, %{
      state: :success,
      job: %Oban.Job{
        worker: "Sentry.MyWorker",
        id: 942,
        meta: %{"cron" => true, "cron_expr" => "* 1 1 1 1", "cron_tz" => "Europe/Rome"}
      }
    })

    assert [[{headers, check_in_body}]] = SentryTest.collect_envelopes(ref, 1)
    id = CheckInIDMappings.lookup_or_insert_new(942)

    assert headers["type"] == "check_in"

    assert_sentry_report(check_in_body,
      check_in_id: id,
      status: "error",
      monitor_slug: "sentry-my-worker",
      duration: 12.099,
      environment: "test",
      monitor_config: %{
        "schedule" => %{
          "type" => "crontab",
          "value" => "* 1 1 1 1"
        },
        "timezone" => "Europe/Rome"
      }
    )
  end

  test "uses default monitor configuration in Sentry's config if present", %{bypass: bypass} do
    put_test_config(
      integrations: [
        monitor_config_defaults: [
          checkin_margin: 10,
          max_runtime: 42,
          failure_issue_threshold: 84
        ]
      ]
    )

    ref = SentryTest.setup_bypass_envelope_collector(bypass, type: "check_in")

    :telemetry.execute([:oban, :job, :exception], %{duration: 0}, %{
      state: :success,
      job: %Oban.Job{
        worker: "Sentry.MyWorker",
        id: 942,
        meta: %{"cron" => true, "cron_expr" => "* 1 1 1 1", "cron_tz" => "Europe/Rome"}
      }
    })

    assert [[{_headers, check_in_body}]] = SentryTest.collect_envelopes(ref, 1)

    assert_sentry_report(check_in_body,
      monitor_config: %{
        "checkin_margin" => 10,
        "failure_issue_threshold" => 84,
        "max_runtime" => 42,
        "schedule" => %{
          "type" => "crontab",
          "value" => "* 1 1 1 1"
        },
        "timezone" => "Europe/Rome"
      }
    )
  end

  @tag attach_opts: [monitor_slug_generator: {__MODULE__, :custom_name_generator}]
  test "monitor_slug is not affected if the custom monitor_name_generator does not target the worker",
       %{bypass: bypass} do
    ref = SentryTest.setup_bypass_envelope_collector(bypass, type: "check_in")

    :telemetry.execute([:oban, :job, :start], %{}, %{
      job: %Oban.Job{
        worker: "Sentry.MyWorker",
        id: 123,
        meta: %{"cron" => true, "cron_expr" => "@daily", "cron_tz" => "Europe/Rome"}
      }
    })

    assert [[{_headers, check_in_body}]] = SentryTest.collect_envelopes(ref, 1)
    assert_sentry_report(check_in_body, monitor_slug: "sentry-my-worker")
  end

  @tag attach_opts: [monitor_slug_generator: {__MODULE__, :custom_name_generator}]
  test "monitor_slug is set based on the custom monitor_name_generator if it targets the worker",
       %{bypass: bypass} do
    client_name = "my-client"
    ref = SentryTest.setup_bypass_envelope_collector(bypass, type: "check_in")

    :telemetry.execute([:oban, :job, :start], %{}, %{
      job: %Oban.Job{
        worker: "Sentry.ClientWorker",
        id: 123,
        args: %{"client" => client_name},
        meta: %{"cron" => true, "cron_expr" => "@daily", "cron_tz" => "Europe/Rome"}
      }
    })

    assert [[{_headers, check_in_body}]] = SentryTest.collect_envelopes(ref, 1)
    assert_sentry_report(check_in_body, monitor_slug: "sentry-client-worker-my-client")
  end

  test "custom options overide job metadata", %{bypass: bypass} do
    ref = SentryTest.setup_bypass_envelope_collector(bypass, type: "check_in")

    defmodule WorkerWithCustomOptions do
      use Oban.Worker

      @behaviour Sentry.Integrations.Oban.Cron

      @impl Oban.Worker
      def perform(_job), do: :ok

      @impl Sentry.Integrations.Oban.Cron
      def sentry_check_in_configuration(job) do
        [
          monitor_slug: "this-is-a-custom-slug-#{job.id}",
          monitor_config: [timezone: "Europe/Rome"]
        ]
      end
    end

    :telemetry.execute([:oban, :job, :start], %{}, %{
      job: %Oban.Job{
        worker: inspect(WorkerWithCustomOptions),
        id: 123,
        args: %{},
        meta: %{"cron" => true, "cron_expr" => "@daily", "cron_tz" => "America/Chicago"}
      }
    })

    assert [[{_headers, check_in_body}]] = SentryTest.collect_envelopes(ref, 1)

    assert_sentry_report(check_in_body,
      monitor_slug: "this-is-a-custom-slug-123",
      monitor_config: %{
        "schedule" => %{"type" => "interval"},
        "timezone" => "Europe/Rome"
      }
    )
  end

  def custom_name_generator(%Oban.Job{worker: "Sentry.ClientWorker", args: %{"client" => client}}) do
    "Sentry.ClientWorker.#{client}"
  end

  def custom_name_generator(%Oban.Job{worker: worker}), do: worker
end
