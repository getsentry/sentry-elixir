defmodule Sentry.LoggerBackendTest do
  use ExUnit.Case

  import Mox

  require Logger

  @moduletag :capture_log

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    {:ok, _} = Logger.add_backend(Sentry.LoggerBackend)

    ExUnit.Callbacks.on_exit(fn ->
      Logger.configure_backend(Sentry.LoggerBackend, [])
      :ok = Logger.remove_backend(Sentry.LoggerBackend)
    end)
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

  test "a logged raised exception is reported" do
    Process.flag(:trap_exit, true)

    ref = expect_sender_call()

    Task.start(fn ->
      raise "Unique Error"
    end)

    assert_receive {^ref, event}
    assert event.exception.type == "RuntimeError"
    assert event.exception.value == "Unique Error"
  end

  test "a GenServer throw is reported" do
    self_pid = self()
    Process.flag(:trap_exit, true)

    ref = expect_sender_call()

    {:ok, pid} = Sentry.TestGenServer.start_link(self_pid)
    Sentry.TestGenServer.do_throw(pid)
    assert_receive {^ref, event}
    assert event.exception.value == ~s[** (exit) bad return value: "I am throwing"]
  end

  test "abnormal GenServer exit is reported" do
    self_pid = self()
    Process.flag(:trap_exit, true)
    ref = expect_sender_call()

    {:ok, pid} = Sentry.TestGenServer.start_link(self_pid)
    Sentry.TestGenServer.bad_exit(pid)
    assert_receive {^ref, event}
    assert event.exception.type == "Sentry.CrashError"
    assert event.exception.value == "** (exit) :bad_exit"
  end

  test "bad function call causing GenServer crash is reported" do
    self_pid = self()
    Process.flag(:trap_exit, true)

    ref = expect_sender_call()

    {:ok, pid} = Sentry.TestGenServer.start_link(self_pid)

    Sentry.TestGenServer.add_sentry_breadcrumb(pid, %{message: "test"})
    Sentry.TestGenServer.invalid_function(pid)
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
    self_pid = self()
    Process.flag(:trap_exit, true)

    ref = expect_sender_call()

    {:ok, pid1} = Sentry.TestGenServer.start_link(self_pid)

    Task.start(fn ->
      GenServer.call(pid1, {:sleep, 20}, 0)
    end)

    assert_receive {^ref, event}

    assert event.exception.type == "Sentry.CrashError"
    assert event.exception.value =~ "** (EXIT) time out"
    assert event.exception.value =~ "GenServer\.call"
  end

  test "captures errors from spawn/0 in Plug app" do
    ref = expect_sender_call()

    :get
    |> Plug.Test.conn("/spawn_error_route")
    |> Plug.run([{Sentry.ExamplePlugApplication, []}])

    assert_receive {^ref, event}

    assert [stacktrace_frame] = event.exception.stacktrace.frames
    assert stacktrace_frame.filename == "test/support/example_plug_application.ex"
  end

  test "sends two errors when a Plug process crashes if cowboy domain is not excluded" do
    Logger.configure_backend(Sentry.LoggerBackend, excluded_domains: [])

    ref = expect_sender_call()

    {:ok, _plug_pid} = Plug.Cowboy.http(Sentry.ExamplePlugApplication, [], port: 8003)

    :hackney.get("http://127.0.0.1:8003/error_route", [], "", [])
    assert_receive {^ref, _event}, 1000
  after
    :ok = Plug.Cowboy.shutdown(Sentry.ExamplePlugApplication.HTTP)
    Logger.configure_backend(Sentry.LoggerBackend, excluded_domains: [:cowboy])
  end

  test "ignores log messages with excluded domains" do
    Logger.configure_backend(Sentry.LoggerBackend,
      capture_log_messages: true,
      excluded_domains: [:test_domain]
    )

    ref = expect_sender_call()

    Logger.error("no domain")
    Logger.error("test_domain", domain: [:test_domain])

    assert_receive {^ref, event}
    assert event.message == "no domain"
  end

  test "includes Logger metadata for keys configured to be included" do
    Logger.configure_backend(Sentry.LoggerBackend, metadata: [:string, :number, :map, :list])
    Process.flag(:trap_exit, true)

    ref = expect_sender_call()

    {:ok, pid} = Sentry.TestGenServer.start_link(self())
    Sentry.TestGenServer.add_logger_metadata(pid, :string, "string")
    Sentry.TestGenServer.add_logger_metadata(pid, :number, 43)
    Sentry.TestGenServer.add_logger_metadata(pid, :map, %{a: "b"})
    Sentry.TestGenServer.add_logger_metadata(pid, :list, [1, 2, 3])
    Sentry.TestGenServer.invalid_function(pid)

    assert_receive {^ref, event}
    assert event.extra.logger_metadata.string == "string"
    assert event.extra.logger_metadata.map == %{a: "b"}
    assert event.extra.logger_metadata.list == [1, 2, 3]
    assert event.extra.logger_metadata.number == 43
  end

  test "does not include Logger metadata when disabled" do
    Logger.configure_backend(Sentry.LoggerBackend, metadata: [])
    Process.flag(:trap_exit, true)
    ref = expect_sender_call()

    {:ok, pid} = Sentry.TestGenServer.start_link(self())
    Sentry.TestGenServer.add_logger_metadata(pid, :string, "string")
    Sentry.TestGenServer.add_logger_metadata(pid, :atom, :atom)
    Sentry.TestGenServer.add_logger_metadata(pid, :number, 43)
    Sentry.TestGenServer.add_logger_metadata(pid, :list, [])
    Sentry.TestGenServer.invalid_function(pid)

    assert_receive {^ref, event}
    assert event.extra.logger_metadata == %{}
  end

  test "sends all messages if :capture_log_messages is true" do
    Logger.configure_backend(Sentry.LoggerBackend, capture_log_messages: true)

    ref = expect_sender_call()

    Logger.error("Testing")

    assert_receive {^ref, event}
    assert event.message == "Testing"
  after
    Logger.configure_backend(Sentry.LoggerBackend, capture_log_messages: false)
  end

  test "sends warning messages when configured to :warning" do
    Logger.configure_backend(Sentry.LoggerBackend,
      level: :warning,
      capture_log_messages: true
    )

    ref = expect_sender_call()

    Sentry.Context.set_user_context(%{user_id: 3})
    Logger.log(:warning, "Testing")

    assert_receive {^ref, event}

    assert event.message == "Testing"
    assert event.user.user_id == 3
  after
    Logger.configure_backend(Sentry.LoggerBackend, level: :error, capture_log_messages: false)
  end

  test "does not send debug messages when configured to :error" do
    Logger.configure_backend(Sentry.LoggerBackend, capture_log_messages: true)

    ref = expect_sender_call()

    Sentry.Context.set_user_context(%{user_id: 3})

    Logger.error("Error")
    Logger.debug("Debug")

    assert_receive {^ref, event}

    assert event.message == "Error"
  after
    Logger.configure_backend(Sentry.LoggerBackend, level: :error, capture_log_messages: false)
  end

  test "Sentry metadata and extra context are retrieved from callers" do
    Logger.configure_backend(Sentry.LoggerBackend, capture_log_messages: true)
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
    Logger.configure_backend(Sentry.LoggerBackend, capture_log_messages: true)
    ref = expect_sender_call()

    dead_pid = spawn(fn -> :ok end)

    Logger.error("Error", callers: [dead_pid, nil])

    assert_receive {^ref, event}
    assert event.message == "Error"
  end

  test "sets event level to Logger message level" do
    Logger.configure_backend(Sentry.LoggerBackend,
      level: :warning,
      capture_log_messages: true
    )

    ref = expect_sender_call()

    Logger.log(:warning, "warn")

    assert_receive {^ref, event}
    assert event.level == "warning"
  after
    Logger.configure_backend(Sentry.LoggerBackend, level: :error, capture_log_messages: false)
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
end
