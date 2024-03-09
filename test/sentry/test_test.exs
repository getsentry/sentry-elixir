defmodule Sentry.TestTest do
  use ExUnit.Case, async: false

  import Sentry.TestHelpers

  alias Sentry.Event
  alias Sentry.Test

  doctest Test

  setup do
    bypass = Bypass.open()
    put_test_config(dsn: "http://public:secret@localhost:#{bypass.port}/1", dedup_events: false)
    %{bypass: bypass}
  end

  test "within a single process" do
    assert :ok = Test.start_collecting_sentry_reports()

    # Start with a clean slate.
    assert Test.pop_sentry_reports() == []

    assert {:ok, ""} = Sentry.capture_message("Oops")
    assert {:ok, ""} = Sentry.capture_message("Another one")

    assert [%Event{} = event1, %Event{} = event2] = Test.pop_sentry_reports()
    assert event1.message.formatted == "Oops"
    assert event2.message.formatted == "Another one"

    # Make sure that popping actually removes the events.
    assert Test.pop_sentry_reports() == []
  end

  test "collecting, reporting, and popping from different processes" do
    process_count = Enum.random(5..10)

    fun = fn index ->
      assert :ok = Test.start_collecting_sentry_reports()

      assert Test.pop_sentry_reports() == []

      assert {:ok, ""} = Sentry.capture_message("Oops #{index}")
      assert {:ok, ""} = Sentry.capture_message("Another one #{index}")

      assert [%Event{} = event1, %Event{} = event2] = Test.pop_sentry_reports()
      assert event1.message.formatted == "Oops #{index}"
      assert event2.message.formatted == "Another one #{index}"

      assert Test.pop_sentry_reports() == []

      :ok
    end

    assert 1..process_count
           |> Enum.map(fn index -> Task.async(fn -> fun.(index) end) end)
           |> Task.await_many(2000) == List.duplicate(:ok, process_count)
  end

  test "reporting from child processes (that have $callers) is allowed even without explicit allowance" do
    parent_pid = self()

    # Collect from self().
    assert :ok = Test.start_collecting_sentry_reports()

    {:ok, child_pid} =
      Task.start_link(fn ->
        receive do
          :go ->
            assert {:ok, ""} = Sentry.capture_message("Oops from child process")
            send(parent_pid, :done)
        end
      end)

    assert {:ok, ""} = Sentry.capture_message("Oops from parent process")

    send(child_pid, :go)
    assert_receive :done

    assert [%Event{} = event1, %Event{} = event2] = Test.pop_sentry_reports()
    assert event1.message.formatted == "Oops from parent process"
    assert event2.message.formatted == "Oops from child process"
  end

  test "explicitly allowing other processes" do
    parent_pid = self()

    # Collect from self().
    assert :ok = Test.start_collecting_sentry_reports()

    {:ok, child_pid} =
      Task.start_link(fn ->
        Process.delete(:"$callers")

        receive do
          :go ->
            assert {:ok, ""} = Sentry.capture_message("Oops from child process")
            send(parent_pid, :done)
        end
      end)

    Test.allow_sentry_reports(parent_pid, child_pid)

    assert {:ok, ""} = Sentry.capture_message("Oops from parent process")

    send(child_pid, :go)
    assert_receive :done

    assert [%Event{} = event1, %Event{} = event2] = Test.pop_sentry_reports()
    assert event1.message.formatted == "Oops from parent process"
    assert event2.message.formatted == "Oops from child process"
  end

  test "explicitly allowing other processes with a lazy PID" do
    parent_pid = self()

    # Collect from self() and allow the lazy child PID.
    assert :ok = Test.start_collecting_sentry_reports()
    Test.allow_sentry_reports(parent_pid, fn -> Process.whereis(:child) end)

    {:ok, child_pid} =
      Task.start_link(fn ->
        Process.delete(:"$callers")

        receive do
          :go ->
            assert {:ok, ""} = Sentry.capture_message("Oops from child process")
            send(parent_pid, :done)
        end
      end)

    Process.register(child_pid, :child)

    Test.allow_sentry_reports(parent_pid, fn -> Process.whereis(:child) end)

    assert {:ok, ""} = Sentry.capture_message("Oops from parent process")

    send(child_pid, :go)
    assert_receive :done

    assert [%Event{} = event1, %Event{} = event2] = Test.pop_sentry_reports()
    assert event1.message.formatted == "Oops from parent process"
    assert event2.message.formatted == "Oops from child process"
  end

  test "reporting from non-allowed child processes", %{bypass: bypass} do
    parent_pid = self()

    Bypass.expect(bypass, fn conn ->
      assert {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert body =~ "Oops from child process"
      Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
    end)

    # Collect from self().
    assert :ok = Test.start_collecting_sentry_reports()

    {:ok, child_pid} =
      Task.start_link(fn ->
        Process.delete(:"$callers")

        receive do
          :go ->
            send(parent_pid, {:done, Sentry.capture_message("Oops from child process")})
        end
      end)

    monitor_ref = Process.monitor(child_pid)
    assert {:ok, ""} = Sentry.capture_message("Oops from parent process")

    send(child_pid, :go)
    assert_receive {:DOWN, ^monitor_ref, _, _, :normal}, 5000
    assert_receive {:done, {:ok, "340"}}, 1000

    assert [%Event{} = event] = Test.pop_sentry_reports()
    assert event.message.formatted == "Oops from parent process"
  end

  test "implementing an expectation-based test workflow" do
    test_pid = self()

    Test.start_collecting(owner: test_pid, cleanup: false)

    on_exit(fn ->
      assert [%Event{} = event] = Test.pop_sentry_reports(test_pid)
      assert event.message.formatted == "Oops"
      assert :ok = Test.cleanup(test_pid)
    end)

    assert {:ok, ""} = Sentry.capture_message("Oops")
  end
end
