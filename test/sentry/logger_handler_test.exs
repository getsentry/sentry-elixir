defmodule Sentry.LoggerHandlerTest do
  use ExUnit.Case

  import Mox

  alias Sentry.TestGenServer

  require Logger

  @moduletag :capture_log

  @handler_name :sentry_handler

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    on_exit(fn ->
      :logger.remove_handler(@handler_name)
    end)
  end

  test "skips logs from a lower level than the configured one" do
    add_handler(%{})

    # Default level is :error.
    Logger.warning("Warning message")

    # Change the level to :info and make sure that :debug messages are not reported.
    assert :ok = :logger.update_handler_config(@handler_name, :level, :info)

    Logger.debug("Debug message")
  end

  test "a logged raised exception is reported" do
    add_handler(%{})

    ref = expect_sender_call()

    Task.start(fn ->
      raise "Unique Error"
    end)

    assert_receive {^ref, event}
    assert event.exception.type == "RuntimeError"
    assert event.exception.value == "Unique Error"
  end

  test "a GenServer throw is reported" do
    add_handler(%{})

    ref = expect_sender_call()

    pid = start_supervised!(TestGenServer)
    TestGenServer.throw(pid)
    assert_receive {^ref, event}
    assert event.exception.value =~ "GenServer #{inspect(pid)} terminating\n"
    assert event.exception.value =~ "** (stop) bad return value: \"I am throwing\"\n"
    assert event.exception.value =~ "Last message: {:\"$gen_cast\", :throw}\n"
    assert event.exception.value =~ "State: []"
    assert event.exception.stacktrace.frames == []
  end

  test "abnormal GenServer exit is reported" do
    add_handler(%{})

    ref = expect_sender_call()

    pid = start_supervised!(TestGenServer)
    TestGenServer.exit(pid)
    assert_receive {^ref, event}
    assert event.exception.type == "message"
    assert event.exception.value =~ "GenServer #{inspect(pid)} terminating\n"
    assert event.exception.value =~ "** (stop) :bad_exit\n"
    assert event.exception.value =~ "Last message: {:\"$gen_cast\", :exit}\n"
    assert event.exception.value =~ "State: []"
  end

  @tag :focus
  test "bad function call causing GenServer crash is reported" do
    add_handler(%{})

    ref = expect_sender_call()

    pid = start_supervised!(TestGenServer)

    TestGenServer.add_sentry_breadcrumb(pid, %{message: "test"})
    TestGenServer.invalid_function(pid)
    assert_receive {^ref, event}

    assert event.exception.type == "FunctionClauseError"
    assert [%{message: "test"}] = event.breadcrumbs

    assert %{
             in_app: false,
             module: NaiveDateTime,
             context_line: nil,
             pre_context: [],
             post_context: []
           } = List.last(event.exception.stacktrace.frames)
  end

  test "GenServer timeout is reported" do
    add_handler(%{})

    ref = expect_sender_call()

    pid = start_supervised!(TestGenServer)

    {:ok, task_pid} =
      Task.start(fn ->
        TestGenServer.sleep(pid, _timeout = 0)
      end)

    assert_receive {^ref, event}

    assert event.exception.type == "message"

    assert event.exception.value =~
             "Task #{inspect(task_pid)} started from #{inspect(self())} terminating\n"

    assert event.exception.value =~ "** (stop) exited in: GenServer.call("
    assert event.exception.value =~ "** (EXIT) time out"
    assert length(event.exception.stacktrace.frames) > 0
  end

  test "captures errors from spawn/0 in Plug app" do
    add_handler(%{})

    ref = expect_sender_call()

    :get
    |> Plug.Test.conn("/spawn_error_route")
    |> Plug.run([{Sentry.ExamplePlugApplication, []}])

    assert_receive {^ref, event}

    assert [stacktrace_frame] = event.exception.stacktrace.frames
    assert stacktrace_frame.filename == "test/support/example_plug_application.ex"
  end

  test "sends two errors when a Plug process crashes if cowboy domain is not excluded" do
    add_handler(%{excluded_domains: []})

    ref = expect_sender_call()

    {:ok, _plug_pid} = Plug.Cowboy.http(Sentry.ExamplePlugApplication, [], port: 8003)

    :hackney.get("http://127.0.0.1:8003/error_route", [], "", [])
    assert_receive {^ref, _event}, 1000
  after
    :ok = Plug.Cowboy.shutdown(Sentry.ExamplePlugApplication.HTTP)
    Logger.configure_backend(Sentry.LoggerBackend, excluded_domains: [:cowboy])
  end

  test "ignores log messages with excluded domains" do
    add_handler(%{capture_log_messages: true, excluded_domains: [:test_domain]})

    ref = expect_sender_call()

    Logger.error("no domain")
    Logger.error("test_domain", domain: [:test_domain])

    assert_receive {^ref, event}
    assert event.message == "no domain"
  end

  test "includes Logger metadata for keys configured to be included" do
    add_handler(%{metadata: [:string, :number, :map, :list]})

    ref = expect_sender_call()

    pid = start_supervised!(TestGenServer)
    TestGenServer.add_logger_metadata(pid, :string, "string")
    TestGenServer.add_logger_metadata(pid, :number, 43)
    TestGenServer.add_logger_metadata(pid, :map, %{a: "b"})
    TestGenServer.add_logger_metadata(pid, :list, [1, 2, 3])
    TestGenServer.invalid_function(pid)

    assert_receive {^ref, event}
    assert event.extra.logger_metadata.string == "string"
    assert event.extra.logger_metadata.map == %{a: "b"}
    assert event.extra.logger_metadata.list == [1, 2, 3]
    assert event.extra.logger_metadata.number == 43
  end

  test "does not include Logger metadata when disabled" do
    add_handler(%{metadata: []})

    ref = expect_sender_call()

    pid = start_supervised!(TestGenServer)
    TestGenServer.add_logger_metadata(pid, :string, "string")
    TestGenServer.add_logger_metadata(pid, :atom, :atom)
    TestGenServer.add_logger_metadata(pid, :number, 43)
    TestGenServer.add_logger_metadata(pid, :list, [])
    TestGenServer.invalid_function(pid)

    assert_receive {^ref, event}
    assert event.extra.logger_metadata == %{}
  end

  test "supports :all for Logger metadata" do
    add_handler(%{metadata: :all})

    ref = expect_sender_call()

    pid = start_supervised!(TestGenServer)
    TestGenServer.add_logger_metadata(pid, :string, "string")
    TestGenServer.invalid_function(pid)

    assert_receive {^ref, event}

    assert event.extra.logger_metadata.string == "string"
    assert event.extra.logger_metadata.domain == [:otp]
    assert is_integer(event.extra.logger_metadata.time)
    assert is_pid(event.extra.logger_metadata.pid)
    assert {%FunctionClauseError{}, _stacktrace} = event.extra.logger_metadata.crash_reason

    # Make sure that all this stuff is serializable.
    assert Sentry.Client.render_event(event).extra.logger_metadata.pid =~ "#PID<"
  end

  test "sends all messages if :capture_log_messages is true" do
    add_handler(%{capture_log_messages: true})

    ref = expect_sender_call()

    Logger.error("Testing")

    assert_receive {^ref, event}
    assert event.message == "Testing"
  after
    Logger.configure_backend(Sentry.LoggerBackend, capture_log_messages: false)
  end

  test "sends warning messages when configured to :warning" do
    add_handler(%{level: :warning, capture_log_messages: true})

    ref = expect_sender_call()

    Sentry.Context.set_user_context(%{user_id: 3})
    Logger.log(:warning, "Testing")

    assert_receive {^ref, event}

    assert event.message == "Testing"
    assert event.user.user_id == 3
  end

  test "does not send debug messages when configured to :error" do
    add_handler(%{capture_log_messages: true})

    ref = expect_sender_call()

    Sentry.Context.set_user_context(%{user_id: 3})

    Logger.error("Error")
    Logger.debug("Debug")

    assert_receive {^ref, event}

    assert event.message == "Error"
  end

  test "Sentry metadata and extra context are retrieved from callers" do
    add_handler(%{capture_log_messages: true})

    ref = expect_sender_call()

    Sentry.Context.set_extra_context(%{day_of_week: "Friday"})
    Sentry.Context.set_user_context(%{user_id: 3})

    {:ok, task} = Task.start_link(__MODULE__, :task, [self()])
    send(task, :go)

    assert_receive {^ref, event}

    assert event.user.user_id == 3
    assert event.extra.day_of_week == "Friday"
    assert event.exception.type == "RuntimeError"
    assert event.exception.value == "oops"
  end

  test "handles malformed :callers metadata" do
    add_handler(%{capture_log_messages: true})

    ref = expect_sender_call()

    dead_pid = spawn(fn -> :ok end)

    Logger.error("Error", callers: [dead_pid, nil])

    assert_receive {^ref, event}
    assert event.message == "Error"
  end

  test "sets event level to Logger message level" do
    add_handler(%{level: :warning, capture_log_messages: true})

    ref = expect_sender_call()

    Logger.log(:warning, "warn")

    assert_receive {^ref, event}
    assert event.level == "warning"
  end

  def task(parent, fun \\ fn -> raise "oops" end) do
    mon = Process.monitor(parent)
    Process.unlink(parent)

    receive do
      :go ->
        fun.()

      {:DOWN, ^mon, _, _, _} ->
        exit(:shutdown)
    end
  end

  defp expect_sender_call do
    pid = self()
    ref = make_ref()

    expect(Sentry.TransportSenderMock, :send_async, fn event ->
      send(pid, {ref, event})
      :ok
    end)

    ref
  end

  defp add_handler(config) do
    assert :ok = :logger.add_handler(@handler_name, Sentry.LoggerHandler, %{config: config})
  end
end
