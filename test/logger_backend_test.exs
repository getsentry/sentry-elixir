defmodule Sentry.LoggerBackendTest do
  use Sentry.Case, async: false

  import Sentry.TestHelpers

  alias Sentry.TestGenServer

  require Logger

  @moduletag :capture_log

  setup do
    assert {:ok, _} = Logger.add_backend(Sentry.LoggerBackend)

    on_exit(fn ->
      Logger.configure_backend(Sentry.LoggerBackend, [])
      :ok = Logger.remove_backend(Sentry.LoggerBackend)
    end)
  end

  test "a logged raised exception is reported" do
    ref = register_before_send()

    Task.start(fn ->
      raise "Unique Error"
    end)

    assert_receive {^ref, event}
    assert [exception] = event.exception
    assert exception.type == "RuntimeError"
    assert exception.value == "Unique Error"
  end

  test "a GenServer throw is reported" do
    ref = register_before_send()

    pid = start_supervised!(TestGenServer)
    TestGenServer.run_async(pid, fn _state -> throw("I am throwing") end)
    assert_receive {^ref, event}
    assert [exception] = event.exception
    assert exception.value =~ ~s<GenServer #{inspect(pid)} terminating\n>
    assert exception.value =~ ~s<** (stop) bad return value: "I am throwing"\n>
    assert exception.value =~ ~s<Last message: {:"$gen_cast",>
    assert exception.value =~ ~s<State: []>
    assert exception.stacktrace.frames == []
  end

  test "abnormal GenServer exit is reported" do
    ref = register_before_send()

    pid = start_supervised!(TestGenServer)
    TestGenServer.run_async(pid, fn state -> {:stop, :bad_exit, state} end)
    assert_receive {^ref, event}
    assert [exception] = event.exception
    assert exception.type == "message"
    assert exception.value =~ ~s<GenServer #{inspect(pid)} terminating\n>
    assert exception.value =~ ~s<** (stop) :bad_exit\n>
    assert exception.value =~ ~s<Last message: {:"$gen_cast",>
    assert exception.value =~ ~s<State: []>
  end

  test "bad function call causing GenServer crash is reported" do
    ref = register_before_send()

    pid = start_supervised!(TestGenServer)

    TestGenServer.run_async(pid, fn state ->
      Sentry.Context.add_breadcrumb(%{message: "test"})
      {:noreply, state}
    end)

    test_genserver_invalid_fun(pid)
    assert_receive {^ref, event}

    assert hd(event.exception).type == "FunctionClauseError"
    assert [%{message: "test"}] = event.breadcrumbs

    assert %{
             in_app: false,
             module: NaiveDateTime,
             context_line: nil,
             pre_context: [],
             post_context: []
           } = List.last(hd(event.exception).stacktrace.frames)
  end

  test "GenServer timeout is reported" do
    ref = register_before_send()

    pid = start_supervised!(TestGenServer)

    {:ok, task_pid} =
      Task.start(fn ->
        TestGenServer.run(pid, fn -> Process.sleep(:infinity) end, _timeout = 0)
      end)

    assert_receive {^ref, event}

    assert [exception] = event.exception

    assert exception.type == "message"

    assert exception.value =~
             "Task #{inspect(task_pid)} started from #{inspect(self())} terminating\n"

    assert exception.value =~ "** (stop) exited in: GenServer.call("
    assert exception.value =~ "** (EXIT) time out"
    assert length(exception.stacktrace.frames) > 0
  end

  test "captures errors from spawn/0 in Plug app" do
    ref = register_before_send()

    :get
    |> Plug.Test.conn("/spawn_error_route")
    |> Plug.run([{Sentry.ExamplePlugApplication, []}])

    assert_receive {^ref, event}

    assert [stacktrace_frame] = hd(event.exception).stacktrace.frames
    assert stacktrace_frame.filename == "test/support/example_plug_application.ex"
  end

  test "sends two errors when a Plug process crashes if cowboy domain is not excluded" do
    Logger.configure_backend(Sentry.LoggerBackend, excluded_domains: [])

    ref = register_before_send()

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

    ref = register_before_send()

    Logger.error("no domain")
    Logger.error("test_domain", domain: [:test_domain])

    assert_receive {^ref, event}
    assert event.message == "no domain"
  end

  test "includes Logger metadata for keys configured to be included" do
    Logger.configure_backend(Sentry.LoggerBackend,
      metadata: [:string, :number, :map, :list, :chardata]
    )

    ref = register_before_send()

    pid = start_supervised!(TestGenServer)

    TestGenServer.run_async(pid, fn state ->
      Logger.metadata(string: "string")
      Logger.metadata(number: 43)
      Logger.metadata(map: %{a: "b"})
      Logger.metadata(list: [1, 2, 3])
      Logger.metadata(chardata: ["π's unicode is", ?\s, [?π]])
      {:noreply, state}
    end)

    test_genserver_invalid_fun(pid)

    assert_receive {^ref, event}
    assert event.extra.logger_metadata.string == "string"
    assert event.extra.logger_metadata.map == %{a: "b"}
    assert event.extra.logger_metadata.list == [1, 2, 3]
    assert event.extra.logger_metadata.number == 43
    assert event.extra.logger_metadata.chardata == "π's unicode is π"
  end

  test "does not include Logger metadata when disabled" do
    Logger.configure_backend(Sentry.LoggerBackend, metadata: [])
    ref = register_before_send()

    pid = start_supervised!(TestGenServer)

    TestGenServer.run_async(pid, fn state ->
      Logger.metadata(string: "string")
      Logger.metadata(atom: :atom)
      Logger.metadata(number: 43)
      Logger.metadata(list: [])
      {:noreply, state}
    end)

    test_genserver_invalid_fun(pid)

    assert_receive {^ref, event}
    assert event.extra.logger_metadata == %{}
  end

  test "supports :all for Logger metadata" do
    Logger.configure_backend(Sentry.LoggerBackend, metadata: :all)
    ref = register_before_send()

    pid = start_supervised!(TestGenServer)

    TestGenServer.run_async(pid, fn state ->
      Logger.metadata(string: "string")
      {:noreply, state}
    end)

    test_genserver_invalid_fun(pid)

    assert_receive {^ref, event}

    assert event.extra.logger_metadata.string == "string"
    assert event.extra.logger_metadata.domain == [:otp]
    assert event.extra.logger_metadata.module == :gen_server
    assert event.extra.logger_metadata.file == "gen_server.erl"
    assert is_integer(event.extra.logger_metadata.time)
    assert is_pid(event.extra.logger_metadata.pid)
    assert {%FunctionClauseError{}, _stacktrace} = event.extra.logger_metadata.crash_reason

    # Make sure that all this stuff is serializable.
    assert Sentry.Client.render_event(event).extra.logger_metadata.pid =~ "#PID<"
  end

  test "sends all messages if :capture_log_messages is true" do
    Logger.configure_backend(Sentry.LoggerBackend, capture_log_messages: true)

    ref = register_before_send()

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

    ref = register_before_send()

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

    ref = register_before_send()

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
    ref = register_before_send()

    Sentry.Context.set_extra_context(%{day_of_week: "Friday"})
    Sentry.Context.set_user_context(%{user_id: 3})

    {:ok, task} = Task.start_link(__MODULE__, :task, [self()])
    send(task, :go)

    assert_receive {^ref, event}

    assert event.user.user_id == 3
    assert event.extra.day_of_week == "Friday"

    assert [exception] = event.exception
    assert exception.type == "RuntimeError"
    assert exception.value == "oops"
  end

  test "handles malformed :callers metadata" do
    Logger.configure_backend(Sentry.LoggerBackend, capture_log_messages: true)
    ref = register_before_send()

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

    ref = register_before_send()

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

  defp register_before_send(_context \\ %{}) do
    pid = self()
    ref = make_ref()

    put_test_config(
      before_send: fn event ->
        send(pid, {ref, event})
        false
      end
    )

    ref
  end

  defp test_genserver_invalid_fun(pid) do
    TestGenServer.run_async(pid, fn _state -> apply(NaiveDateTime, :from_erl, [{}, {}, {}]) end)
  end
end
