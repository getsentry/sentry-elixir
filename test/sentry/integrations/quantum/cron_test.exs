defmodule Sentry.Integrations.Quantum.CronTest do
  use Sentry.Case, async: false

  import Sentry.TestHelpers

  defmodule Scheduler do
    use Quantum, otp_app: :sentry
  end

  setup_all do
    Sentry.Integrations.Quantum.Cron.attach_telemetry_handler()
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
    test_pid = self()
    ref = make_ref()

    Bypass.expect_once(bypass, "POST", "/api/1/envelope/", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert [{headers, check_in_body}] = decode_envelope!(body)

      assert headers["type"] == "check_in"

      assert check_in_body["check_in_id"] == "quantum-#{:erlang.phash2(ref)}"
      assert check_in_body["status"] == "in_progress"
      assert check_in_body["monitor_slug"] == "quantum-test-job"
      assert check_in_body["duration"] == nil
      assert check_in_body["environment"] == "test"

      assert check_in_body["monitor_config"] == %{
               "schedule" => %{
                 "type" => "crontab",
                 "value" => "0 0 * * * *"
               }
             }

      send(test_pid, {ref, :done})

      Plug.Conn.send_resp(conn, 200, ~s<{"id": "1923"}>)
    end)

    :telemetry.execute([:quantum, :job, :start], %{}, %{
      job:
        Scheduler.new_job(
          name: :test_job,
          schedule: Crontab.CronExpression.Parser.parse!("@daily")
        ),
      telemetry_span_context: ref
    })

    assert_receive {^ref, :done}, 1000
  end

  test "captures exception events with monitor config", %{bypass: bypass} do
    test_pid = self()
    ref = make_ref()

    Bypass.expect_once(bypass, "POST", "/api/1/envelope/", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert [{headers, check_in_body}] = decode_envelope!(body)

      assert headers["type"] == "check_in"

      assert check_in_body["check_in_id"] == "quantum-#{:erlang.phash2(ref)}"
      assert check_in_body["status"] == "error"
      assert check_in_body["monitor_slug"] == "quantum-test-job"
      assert check_in_body["duration"] == 12.099
      assert check_in_body["environment"] == "test"

      assert check_in_body["monitor_config"] == %{
               "schedule" => %{
                 "type" => "crontab",
                 "value" => "0 0 * * * *"
               }
             }

      send(test_pid, {ref, :done})

      Plug.Conn.send_resp(conn, 200, ~s<{"id": "1923"}>)
    end)

    duration = System.convert_time_unit(12_099, :millisecond, :native)

    :telemetry.execute([:quantum, :job, :exception], %{duration: duration}, %{
      job:
        Scheduler.new_job(
          name: :test_job,
          schedule: Crontab.CronExpression.Parser.parse!("@daily")
        ),
      telemetry_span_context: ref
    })

    assert_receive {^ref, :done}, 1000
  end

  test "captures stop events with monitor config", %{bypass: bypass} do
    test_pid = self()
    ref = make_ref()

    Bypass.expect_once(bypass, "POST", "/api/1/envelope/", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert [{headers, check_in_body}] = decode_envelope!(body)

      assert headers["type"] == "check_in"

      assert check_in_body["check_in_id"] == "quantum-#{:erlang.phash2(ref)}"
      assert check_in_body["status"] == "ok"
      assert check_in_body["monitor_slug"] == "quantum-test-job"
      assert check_in_body["duration"] == 12.099
      assert check_in_body["environment"] == "test"

      assert check_in_body["monitor_config"] == %{
               "schedule" => %{
                 "type" => "crontab",
                 "value" => "0 0 * * * *"
               }
             }

      send(test_pid, {ref, :done})

      Plug.Conn.send_resp(conn, 200, ~s<{"id": "1923"}>)
    end)

    duration = System.convert_time_unit(12_099, :millisecond, :native)

    :telemetry.execute([:quantum, :job, :stop], %{duration: duration}, %{
      job:
        Scheduler.new_job(
          name: :test_job,
          schedule: Crontab.CronExpression.Parser.parse!("@daily")
        ),
      telemetry_span_context: ref
    })

    assert_receive {^ref, :done}, 1000
  end

  for {job_name, expected_slug} <- [
        {:some_job, "quantum-some-job"},
        {MyApp.MyJob, "quantum-my-app-my-job"}
      ] do
    test "works for a job named #{inspect(job_name)}", %{bypass: bypass} do
      test_pid = self()
      ref = make_ref()

      Bypass.expect_once(bypass, "POST", "/api/1/envelope/", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert [{_headers, check_in_body}] = decode_envelope!(body)

        assert check_in_body["monitor_slug"] == unquote(expected_slug)
        send(test_pid, {ref, :done})

        Plug.Conn.send_resp(conn, 200, ~s<{"id": "1923"}>)
      end)

      duration = System.convert_time_unit(12_099, :millisecond, :native)

      :telemetry.execute([:quantum, :job, :stop], %{duration: duration}, %{
        job:
          Scheduler.new_job(
            name: unquote(job_name),
            schedule: Crontab.CronExpression.Parser.parse!("@daily")
          ),
        telemetry_span_context: ref
      })

      assert_receive {^ref, :done}, 1000
    end
  end

  test "works for a job without the name", %{bypass: bypass} do
    test_pid = self()
    ref = make_ref()

    Bypass.expect_once(bypass, "POST", "/api/1/envelope/", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert [{_headers, check_in_body}] = decode_envelope!(body)

      assert check_in_body["monitor_slug"] == "quantum-generic-job"
      send(test_pid, {ref, :done})

      Plug.Conn.send_resp(conn, 200, ~s<{"id": "1923"}>)
    end)

    duration = System.convert_time_unit(12_099, :millisecond, :native)

    :telemetry.execute([:quantum, :job, :stop], %{duration: duration}, %{
      job: Scheduler.new_job(schedule: Crontab.CronExpression.Parser.parse!("@daily")),
      telemetry_span_context: ref
    })

    assert_receive {^ref, :done}, 1000
  end
end
