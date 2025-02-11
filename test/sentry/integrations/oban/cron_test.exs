defmodule Sentry.Integrations.Oban.CronTest do
  alias Sentry.Integrations.CheckInIDMappings
  use Sentry.Case, async: false

  import Sentry.TestHelpers

  setup context do
    opts = context[:attach_opts] || []

    Sentry.Integrations.Oban.Cron.attach_telemetry_handler(opts)
    on_exit(fn -> :telemetry.detach(Sentry.Integrations.Oban.Cron) end)
  end

  setup do
    bypass = Bypass.open()

    put_test_config(
      dsn: "http://public:secret@localhost:#{bypass.port}/1",
      dedup_events: false,
      environment_name: "test"
    )

    %{bypass: bypass}
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

    test "ignores #{event_type} events with a cron expr that is not a string", %{bypass: bypass} do
      Bypass.down(bypass)

      :telemetry.execute([:oban, :job, unquote(event_type)], %{}, %{
        job: %Oban.Job{worker: "Sentry.MyWorker", meta: %{"cron" => true, "cron_expr" => 123}}
      })
    end
  end

  test "captures start events with monitor config", %{bypass: bypass} do
    test_pid = self()
    ref = make_ref()

    Bypass.expect_once(bypass, "POST", "/api/1/envelope/", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert [{headers, check_in_body}] = decode_envelope!(body)
      id = CheckInIDMappings.lookup_or_insert_new(123)

      assert headers["type"] == "check_in"

      assert check_in_body["check_in_id"] == id
      assert check_in_body["status"] == "in_progress"
      assert check_in_body["monitor_slug"] == "sentry-my-worker"
      assert check_in_body["duration"] == nil
      assert check_in_body["environment"] == "test"

      assert check_in_body["monitor_config"] == %{
               "schedule" => %{
                 "type" => "interval",
                 "unit" => "day",
                 "value" => 1
               }
             }

      send(test_pid, {ref, :done})

      Plug.Conn.send_resp(conn, 200, ~s<{"id": "1923"}>)
    end)

    :telemetry.execute([:oban, :job, :start], %{}, %{
      job: %Oban.Job{
        worker: "Sentry.MyWorker",
        id: 123,
        meta: %{"cron" => true, "cron_expr" => "@daily"}
      }
    })

    assert_receive {^ref, :done}, 1000
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
      test_pid = self()
      ref = make_ref()

      Bypass.expect_once(bypass, "POST", "/api/1/envelope/", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert [{headers, check_in_body}] = decode_envelope!(body)
        id = CheckInIDMappings.lookup_or_insert_new(942)

        assert headers["type"] == "check_in"
        assert check_in_body["check_in_id"] == id
        assert check_in_body["status"] == unquote(expected_status)
        assert check_in_body["monitor_slug"] == "sentry-my-worker"
        assert check_in_body["duration"] == 12.099
        assert check_in_body["environment"] == "test"

        assert check_in_body["monitor_config"] == %{
                 "schedule" => %{
                   "type" => "interval",
                   "value" => 1,
                   "unit" => unquote(expected_unit)
                 },
                 "timezone" => "Europe/Rome"
               }

        send(test_pid, {ref, :done})

        Plug.Conn.send_resp(conn, 200, ~s<{"id": "1923"}>)
      end)

      duration = System.convert_time_unit(12_099, :millisecond, :native)

      :telemetry.execute([:oban, :job, :stop], %{duration: duration}, %{
        state: unquote(oban_state),
        job: %Oban.Job{
          worker: "Sentry.MyWorker",
          id: 942,
          meta: %{"cron" => true, "cron_expr" => unquote(frequency), "cron_tz" => "Europe/Rome"}
        }
      })

      assert_receive {^ref, :done}, 1000
    end
  end

  test "captures exception events with monitor config", %{bypass: bypass} do
    test_pid = self()
    ref = make_ref()

    Bypass.expect_once(bypass, "POST", "/api/1/envelope/", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert [{headers, check_in_body}] = decode_envelope!(body)
      id = CheckInIDMappings.lookup_or_insert_new(942)

      assert headers["type"] == "check_in"

      assert check_in_body["check_in_id"] == id
      assert check_in_body["status"] == "error"
      assert check_in_body["monitor_slug"] == "sentry-my-worker"
      assert check_in_body["duration"] == 12.099
      assert check_in_body["environment"] == "test"

      assert check_in_body["monitor_config"] == %{
               "schedule" => %{
                 "type" => "crontab",
                 "value" => "* 1 1 1 1"
               },
               "timezone" => "Europe/Rome"
             }

      send(test_pid, {ref, :done})

      Plug.Conn.send_resp(conn, 200, ~s<{"id": "1923"}>)
    end)

    duration = System.convert_time_unit(12_099, :millisecond, :native)

    :telemetry.execute([:oban, :job, :exception], %{duration: duration}, %{
      state: :success,
      job: %Oban.Job{
        worker: "Sentry.MyWorker",
        id: 942,
        meta: %{"cron" => true, "cron_expr" => "* 1 1 1 1", "cron_tz" => "Europe/Rome"}
      }
    })

    assert_receive {^ref, :done}, 1000
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

    test_pid = self()
    ref = make_ref()

    Bypass.expect_once(bypass, "POST", "/api/1/envelope/", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert [{_headers, check_in_body}] = decode_envelope!(body)

      assert check_in_body["monitor_config"] == %{
               "checkin_margin" => 10,
               "failure_issue_threshold" => 84,
               "max_runtime" => 42,
               "schedule" => %{
                 "type" => "crontab",
                 "value" => "* 1 1 1 1"
               },
               "timezone" => "Europe/Rome"
             }

      send(test_pid, {ref, :done})

      Plug.Conn.send_resp(conn, 200, ~s<{"id": "1923"}>)
    end)

    :telemetry.execute([:oban, :job, :exception], %{duration: 0}, %{
      state: :success,
      job: %Oban.Job{
        worker: "Sentry.MyWorker",
        id: 942,
        meta: %{"cron" => true, "cron_expr" => "* 1 1 1 1", "cron_tz" => "Europe/Rome"}
      }
    })

    assert_receive {^ref, :done}, 1000
  end

  @tag attach_opts: [monitor_slug_generator: {__MODULE__, :custom_name_generator}]
  test "monitor_slug is not affected if the custom monitor_name_generator does not target the worker",
       %{bypass: bypass} do
    test_pid = self()
    ref = make_ref()

    Bypass.expect_once(bypass, "POST", "/api/1/envelope/", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert [{_headers, check_in_body}] = decode_envelope!(body)
      assert check_in_body["monitor_slug"] == "sentry-my-worker"
      send(test_pid, {ref, :done})

      Plug.Conn.send_resp(conn, 200, ~s<{"id": "1923"}>)
    end)

    :telemetry.execute([:oban, :job, :start], %{}, %{
      job: %Oban.Job{
        worker: "Sentry.MyWorker",
        id: 123,
        meta: %{"cron" => true, "cron_expr" => "@daily", "cron_tz" => "Europe/Rome"}
      }
    })

    assert_receive {^ref, :done}, 1000
  end

  @tag attach_opts: [monitor_slug_generator: {__MODULE__, :custom_name_generator}]
  test "monitor_slug is set based on the custom monitor_name_generator if it targets the worker",
       %{bypass: bypass} do
    client_name = "my-client"
    test_pid = self()
    ref = make_ref()

    Bypass.expect_once(bypass, "POST", "/api/1/envelope/", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert [{_headers, check_in_body}] = decode_envelope!(body)
      assert check_in_body["monitor_slug"] == "sentry-client-worker-my-client"
      send(test_pid, {ref, :done})

      Plug.Conn.send_resp(conn, 200, ~s<{"id": "1923"}>)
    end)

    :telemetry.execute([:oban, :job, :start], %{}, %{
      job: %Oban.Job{
        worker: "Sentry.ClientWorker",
        id: 123,
        args: %{"client" => client_name},
        meta: %{"cron" => true, "cron_expr" => "@daily", "cron_tz" => "Europe/Rome"}
      }
    })

    assert_receive {^ref, :done}, 1000
  end

  test "custom options overide job metadata", %{bypass: bypass} do
    test_pid = self()
    ref = make_ref()

    Bypass.expect_once(bypass, "POST", "/api/1/envelope/", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert [{_headers, check_in_body}] = decode_envelope!(body)

      assert check_in_body["monitor_slug"] == "this-is-a-custom-slug-123"
      assert check_in_body["monitor_config"]["schedule"]["type"] == "interval"
      assert check_in_body["monitor_config"]["timezone"] == "Europe/Rome"

      send(test_pid, {ref, :done})

      Plug.Conn.send_resp(conn, 200, ~s<{"id": "1923"}>)
    end)

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

    assert_receive {^ref, :done}, 1000
  end

  def custom_name_generator(%Oban.Job{worker: "Sentry.ClientWorker", args: %{"client" => client}}) do
    "Sentry.ClientWorker.#{client}"
  end

  def custom_name_generator(%Oban.Job{worker: worker}), do: worker
end
