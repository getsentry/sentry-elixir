defmodule Sentry.Cron.ObanTest do
  use Sentry.Case, async: false

  import Sentry.TestHelpers

  # TODO: Oban requires Elixir 1.13+, remove this once we depend on that too.
  if not Version.match?(System.version(), "~> 1.13") do
    @moduletag :skip
  end

  setup_all do
    Sentry.Cron.Oban.attach_telemetry_handler()
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

  test "captures start events", %{bypass: bypass} do
    test_pid = self()
    ref = make_ref()

    Bypass.expect_once(bypass, "POST", "/api/1/envelope/", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert [{headers, check_in_body}] = decode_envelope!(body)

      assert headers["type"] == "check_in"

      assert check_in_body["check_in_id"] == "oban-123"
      assert check_in_body["status"] == "in_progress"
      assert check_in_body["monitor_slug"] == "Sentry.MyWorker"
      assert check_in_body["duration"] == nil
      assert check_in_body["environment"] == "test"

      send(test_pid, {ref, :done})

      Plug.Conn.send_resp(conn, 200, ~s<{"id": "1923"}>)
    end)

    :telemetry.execute([:oban, :job, :start], %{}, %{
      job: %Oban.Job{worker: "Sentry.MyWorker", id: 123}
    })

    assert_receive {^ref, :done}, 1000
  end

  test "captures stop events", %{bypass: bypass} do
    test_pid = self()
    ref = make_ref()

    Bypass.expect_once(bypass, "POST", "/api/1/envelope/", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert [{headers, check_in_body}] = decode_envelope!(body)

      assert headers["type"] == "check_in"

      assert check_in_body["check_in_id"] == "oban-942"
      assert check_in_body["status"] == "ok"
      assert check_in_body["monitor_slug"] == "Sentry.MyWorker"
      assert check_in_body["duration"] == 12.099
      assert check_in_body["environment"] == "test"

      send(test_pid, {ref, :done})

      Plug.Conn.send_resp(conn, 200, ~s<{"id": "1923"}>)
    end)

    duration = System.convert_time_unit(12_099, :millisecond, :native)

    :telemetry.execute([:oban, :job, :stop], %{duration: duration}, %{
      state: :success,
      job: %Oban.Job{worker: "Sentry.MyWorker", id: 942}
    })

    assert_receive {^ref, :done}, 1000
  end

  test "captures exception events", %{bypass: bypass} do
    test_pid = self()
    ref = make_ref()

    Bypass.expect_once(bypass, "POST", "/api/1/envelope/", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert [{headers, check_in_body}] = decode_envelope!(body)

      assert headers["type"] == "check_in"

      assert check_in_body["check_in_id"] == "oban-942"
      assert check_in_body["status"] == "error"
      assert check_in_body["monitor_slug"] == "Sentry.MyWorker"
      assert check_in_body["duration"] == 12.099
      assert check_in_body["environment"] == "test"

      send(test_pid, {ref, :done})

      Plug.Conn.send_resp(conn, 200, ~s<{"id": "1923"}>)
    end)

    duration = System.convert_time_unit(12_099, :millisecond, :native)

    :telemetry.execute([:oban, :job, :exception], %{duration: duration}, %{
      state: :success,
      job: %Oban.Job{worker: "Sentry.MyWorker", id: 942}
    })

    assert_receive {^ref, :done}, 1000
  end
end
