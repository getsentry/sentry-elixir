defmodule Sentry.Integrations.Oban.CronTest do
  use Sentry.Case, async: false

  import Sentry.TestHelpers

  setup_all do
    Sentry.Integrations.Oban.Cron.attach_telemetry_handler()
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
        job: %Oban.Job{meta: %{"cron" => true, "cron_expr" => "@reboot"}}
      })
    end

    test "ignores #{event_type} events with a cron expr that is not a string", %{bypass: bypass} do
      Bypass.down(bypass)

      :telemetry.execute([:oban, :job, unquote(event_type)], %{}, %{
        job: %Oban.Job{meta: %{"cron" => true, "cron_expr" => 123}}
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

      assert check_in_body["check_in_id"] == "oban-123"
      assert check_in_body["status"] == "in_progress"
      assert check_in_body["monitor_slug"] == "sentry-my-worker"
      assert check_in_body["duration"] == nil
      assert check_in_body["environment"] == "test"

      assert check_in_body["monitor_config"] == %{
               "schedule" => %{
                 "type" => "interval",
                 "value" => 1,
                 "unit" => "day"
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

        assert headers["type"] == "check_in"

        assert check_in_body["check_in_id"] == "oban-942"
        assert check_in_body["status"] == unquote(expected_status)
        assert check_in_body["monitor_slug"] == "sentry-my-worker"
        assert check_in_body["duration"] == 12.099
        assert check_in_body["environment"] == "test"

        assert check_in_body["monitor_config"] == %{
                 "schedule" => %{
                   "type" => "interval",
                   "value" => 1,
                   "unit" => unquote(expected_unit)
                 }
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
          meta: %{"cron" => true, "cron_expr" => unquote(frequency)}
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

      assert headers["type"] == "check_in"

      assert check_in_body["check_in_id"] == "oban-942"
      assert check_in_body["status"] == "error"
      assert check_in_body["monitor_slug"] == "sentry-my-worker"
      assert check_in_body["duration"] == 12.099
      assert check_in_body["environment"] == "test"

      assert check_in_body["monitor_config"] == %{
               "schedule" => %{
                 "type" => "crontab",
                 "value" => "* 1 1 1 1"
               }
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
        meta: %{"cron" => true, "cron_expr" => "* 1 1 1 1"}
      }
    })

    assert_receive {^ref, :done}, 1000
  end
end
