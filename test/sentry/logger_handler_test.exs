defmodule Sentry.LoggerHandlerTest do
  use ExUnit.Case, async: false

  import Mox

  alias Sentry.TestGenServer

  require Logger

  @moduletag :capture_log

  @handler_name :sentry_handler

  setup :set_mox_global
  setup :verify_on_exit!

  setup :stub_sender_call

  setup do
    on_exit(fn ->
      _ = :logger.remove_handler(@handler_name)
    end)
  end

  test "skips logs from a lower level than the configured one" do
    add_handler(%{})

    # Default level is :error, so this doesn't get reported.
    Logger.warning("Warning message")

    # Change the level to :info and make sure that :debug messages are not reported.
    assert :ok = :logger.update_handler_config(@handler_name, :level, :info)

    Logger.debug("Debug message")
  end

  test "a logged raised exception is reported", %{sender_ref: ref} do
    add_handler(%{})

    Task.start(fn ->
      raise "Unique Error"
    end)

    assert_receive {^ref, event}
    assert event.exception.type == "RuntimeError"
    assert event.exception.value == "Unique Error"
  end

  test "a GenServer throw is reported", %{sender_ref: ref} do
    add_handler(%{})

    pid = start_supervised!(TestGenServer)
    TestGenServer.throw(pid)
    assert_receive {^ref, event}
    assert event.message =~ "** (stop) bad return value: \"I am throwing\""
  end

  test "abnormal GenServer exit is reported", %{sender_ref: ref} do
    add_handler(%{})

    pid = start_supervised!(TestGenServer)
    TestGenServer.exit(pid)
    assert_receive {^ref, event}

    assert event.message =~ "** (stop) :bad_exit"

    if System.otp_release() >= "26" do
      assert event.exception.type == "message"
    end
  end

  test "bad function call causing GenServer crash is reported", %{sender_ref: ref} do
    add_handler(%{})

    pid = start_supervised!(TestGenServer)

    TestGenServer.add_sentry_breadcrumb(pid, %{message: "test"})
    TestGenServer.invalid_function(pid)
    assert_receive {^ref, event}

    assert [%{message: "test"}] = event.breadcrumbs

    if System.otp_release() >= "26" do
      assert event.exception.type == "FunctionClauseError"
    else
      assert event.message =~ "** (stop) :function_clause"
      assert event.exception.type == "message"
    end

    assert %{
             in_app: false,
             module: NaiveDateTime,
             context_line: nil,
             pre_context: [],
             post_context: []
           } = List.last(event.exception.stacktrace.frames)
  end

  test "GenServer timeout is reported", %{sender_ref: ref} do
    add_handler(%{})

    pid = start_supervised!(TestGenServer)

    Task.start(fn ->
      TestGenServer.sleep(pid, _timeout = 0)
    end)

    assert_receive {^ref, event}

    assert event.exception.type == "message"

    assert event.exception.value =~ "** (stop) exited in: GenServer.call("
    assert event.exception.value =~ "** (EXIT) time out"
    assert length(event.exception.stacktrace.frames) > 0
  end

  if System.otp_release() >= "26.0" do
    test "captures errors from spawn/0 in Plug app", %{sender_ref: ref} do
      add_handler(%{excluded_domains: []})

      :get
      |> Plug.Test.conn("/spawn_error_route")
      |> Plug.run([{Sentry.ExamplePlugApplication, []}])

      assert_receive {^ref, event}

      if System.otp_release() >= "26" do
        assert [stacktrace_frame] = event.exception.stacktrace.frames
        assert stacktrace_frame.filename == "test/support/example_plug_application.ex"
      else
        assert event.message =~ "Error in process"
        assert event.message =~ "RuntimeError"
      end
    end

    test "sends two errors when a Plug process crashes if cowboy domain is not excluded", %{
      sender_ref: ref
    } do
      add_handler(%{excluded_domains: []})

      {:ok, _plug_pid} = Plug.Cowboy.http(Sentry.ExamplePlugApplication, [], port: 8003)

      :hackney.get("http://127.0.0.1:8003/error_route", [], "", [])
      assert_receive {^ref, _event}, 1000
    after
      :ok = Plug.Cowboy.shutdown(Sentry.ExamplePlugApplication.HTTP)
      Logger.configure_backend(Sentry.LoggerBackend, excluded_domains: [:cowboy])
    end
  end

  test "ignores log messages with excluded domains", %{sender_ref: ref} do
    add_handler(%{capture_log_messages: true, excluded_domains: [:test_domain]})

    Logger.error("no domain")
    Logger.error("test_domain", domain: [:test_domain])

    assert_receive {^ref, event}
    assert event.message == "no domain"
  end

  test "includes Logger metadata for keys configured to be included", %{sender_ref: ref} do
    add_handler(%{metadata: [:string, :number, :map, :list]})

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

  test "does not include Logger metadata when disabled", %{sender_ref: ref} do
    add_handler(%{metadata: []})

    pid = start_supervised!(TestGenServer)
    TestGenServer.add_logger_metadata(pid, :string, "string")
    TestGenServer.add_logger_metadata(pid, :atom, :atom)
    TestGenServer.add_logger_metadata(pid, :number, 43)
    TestGenServer.add_logger_metadata(pid, :list, [])
    TestGenServer.invalid_function(pid)

    assert_receive {^ref, event}
    assert event.extra.logger_metadata == %{}
  end

  test "supports :all for Logger metadata", %{sender_ref: ref} do
    add_handler(%{metadata: :all})

    pid = start_supervised!(TestGenServer)
    TestGenServer.add_logger_metadata(pid, :string, "string")
    TestGenServer.invalid_function(pid)

    assert_receive {^ref, event}

    assert event.extra.logger_metadata.string == "string"
    assert event.extra.logger_metadata.domain == [:otp]
    assert is_integer(event.extra.logger_metadata.time)
    assert is_pid(event.extra.logger_metadata.pid)

    if System.otp_release() >= "26" do
      assert {%FunctionClauseError{}, _stacktrace} = event.extra.logger_metadata.crash_reason
    end

    # Make sure that all this stuff is serializable.
    assert Sentry.Client.render_event(event).extra.logger_metadata.pid =~ "#PID<"
  end

  test "sends all messages if :capture_log_messages is true", %{sender_ref: ref} do
    add_handler(%{capture_log_messages: true})

    Logger.error("Testing")

    assert_receive {^ref, event}
    assert event.message == "Testing"
  after
    Logger.configure_backend(Sentry.LoggerBackend, capture_log_messages: false)
  end

  test "sends warning messages when configured to :warning", %{sender_ref: ref} do
    add_handler(%{level: :warning, capture_log_messages: true})

    Sentry.Context.set_user_context(%{user_id: 3})
    Logger.log(:warning, "Testing")

    assert_receive {^ref, event}

    assert event.message == "Testing"
    assert event.user.user_id == 3
  end

  test "does not send debug messages when configured to :error", %{sender_ref: ref} do
    add_handler(%{capture_log_messages: true})

    Sentry.Context.set_user_context(%{user_id: 3})

    Logger.error("Error")
    Logger.debug("Debug")

    assert_receive {^ref, event}

    assert event.message == "Error"
  end

  test "Sentry metadata and extra context are retrieved from callers", %{sender_ref: ref} do
    add_handler(%{capture_log_messages: true})

    Sentry.Context.set_extra_context(%{day_of_week: "Friday"})
    Sentry.Context.set_user_context(%{user_id: 3})

    {:ok, _task_pid} = Task.start(__MODULE__, :task, [])

    assert_receive {^ref, event}

    assert event.user.user_id == 3
    assert event.extra.day_of_week == "Friday"
    assert event.exception.type == "RuntimeError"
    assert event.exception.value == "oops"
  end

  test "handles malformed :callers metadata", %{sender_ref: ref} do
    add_handler(%{capture_log_messages: true})

    dead_pid = spawn(fn -> :ok end)

    Logger.error("Error", callers: [dead_pid, nil])

    assert_receive {^ref, event}
    assert event.message == "Error"
  end

  test "sets event level to Logger message level", %{sender_ref: ref} do
    add_handler(%{level: :warning, capture_log_messages: true})

    Logger.log(:warning, "warn")

    assert_receive {^ref, event}
    assert event.level == "warning"
  end

  def task do
    raise "oops"
  end

  defp stub_sender_call(_context) do
    pid = self()
    ref = make_ref()

    stub(Sentry.TransportSenderMock, :send_async, fn event ->
      send(pid, {ref, event})
      :ok
    end)

    %{sender_ref: ref}
  end

  defp add_handler(config) do
    assert :ok = :logger.add_handler(@handler_name, Sentry.LoggerHandler, %{config: config})
  end
end
