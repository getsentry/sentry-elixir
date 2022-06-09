defmodule Sentry.LoggerBackendTest do
  use ExUnit.Case
  import ExUnit.CaptureLog
  import Sentry.TestEnvironmentHelper
  require Logger

  alias Sentry.Envelope

  setup do
    {:ok, _} = Logger.add_backend(Sentry.LoggerBackend)

    ExUnit.Callbacks.on_exit(fn ->
      Logger.configure_backend(Sentry.LoggerBackend, [])
      :ok = Logger.remove_backend(Sentry.LoggerBackend)
    end)
  end

  test "exception makes call to Sentry API" do
    Process.flag(:trap_exit, true)
    bypass = Bypass.open()
    pid = self()

    Bypass.expect(bypass, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert body =~ "RuntimeError"
      assert body =~ "Unique Error"
      assert conn.request_path == "/api/1/envelope/"
      assert conn.method == "POST"
      send(pid, "API called")
      Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
    end)

    modify_env(:sentry, dsn: "http://public:secret@localhost:#{bypass.port}/1")

    capture_log(fn ->
      Task.start(fn ->
        raise "Unique Error"
      end)

      assert_receive "API called"
    end)
  end

  test "GenServer throw makes call to Sentry API" do
    self_pid = self()
    Process.flag(:trap_exit, true)
    bypass = Bypass.open()

    Bypass.expect(bypass, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      event =
        body
        |> Envelope.from_binary!()
        |> Envelope.event()

      assert List.first(event.exception)["value"] ==
               ~s[** (exit) bad return value: "I am throwing"]

      assert conn.request_path == "/api/1/envelope/"
      assert conn.method == "POST"
      send(self_pid, "API called")
      Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
    end)

    modify_env(:sentry, dsn: "http://public:secret@localhost:#{bypass.port}/1")

    capture_log(fn ->
      {:ok, pid} = Sentry.TestGenServer.start_link(self_pid)
      Sentry.TestGenServer.do_throw(pid)
      assert_receive "terminating"
      assert_receive "API called"
    end)
  end

  test "abnormal GenServer exit makes call to Sentry API" do
    self_pid = self()
    Process.flag(:trap_exit, true)
    bypass = Bypass.open()

    Bypass.expect(bypass, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      event =
        body
        |> Envelope.from_binary!()
        |> Envelope.event()

      assert List.first(event.exception)["type"] == "Sentry.CrashError"
      assert List.first(event.exception)["value"] == "** (exit) :bad_exit"
      assert conn.request_path == "/api/1/envelope/"
      assert conn.method == "POST"
      send(self_pid, "API called")
      Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
    end)

    modify_env(:sentry, dsn: "http://public:secret@localhost:#{bypass.port}/1")

    capture_log(fn ->
      {:ok, pid} = Sentry.TestGenServer.start_link(self_pid)
      Sentry.TestGenServer.bad_exit(pid)
      assert_receive "terminating"
      assert_receive "API called"
    end)
  end

  test "Bad function call causing GenServer crash makes call to Sentry API" do
    self_pid = self()
    Process.flag(:trap_exit, true)
    bypass = Bypass.open()

    Bypass.expect(bypass, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      event =
        body
        |> Envelope.from_binary!()
        |> Envelope.event()

      assert %{
               "in_app" => false,
               "module" => "Elixir.NaiveDateTime",
               "context_line" => nil,
               "pre_context" => [],
               "post_context" => []
             } = List.last(event.stacktrace.frames)

      assert [%{"test" => "test", "timestamp" => _}] = event.breadcrumbs

      assert List.first(event.exception)["type"] == "FunctionClauseError"
      assert conn.request_path == "/api/1/envelope/"
      assert conn.method == "POST"
      send(self_pid, "API called")
      Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
    end)

    modify_env(:sentry, dsn: "http://public:secret@localhost:#{bypass.port}/1")

    capture_log(fn ->
      {:ok, pid} = Sentry.TestGenServer.start_link(self_pid)

      Sentry.TestGenServer.add_sentry_breadcrumb(pid, %{test: "test"})
      Sentry.TestGenServer.invalid_function(pid)
      assert_receive "terminating"
      assert_receive "API called"
      Bypass.down(bypass)
    end)
  end

  test "captures errors from spawn() in Plug app" do
    bypass = Bypass.open()
    pid = self()

    Bypass.expect(bypass, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      event =
        body
        |> Envelope.from_binary!()
        |> Envelope.event()

      assert length(event.stacktrace.frames) == 1

      assert List.first(event.stacktrace.frames)["filename"] ==
               "test/support/example_plug_application.ex"

      send(pid, "API called")
      Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
    end)

    modify_env(:sentry, dsn: "http://public:secret@localhost:#{bypass.port}/1")

    capture_log(fn ->
      Plug.Test.conn(:get, "/spawn_error_route")
      |> Sentry.ExamplePlugApplication.call([])

      assert_receive "API called"
    end)
  end

  test "GenServer timeout makes call to Sentry API" do
    self_pid = self()
    Process.flag(:trap_exit, true)
    bypass = Bypass.open()

    Bypass.expect(bypass, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      event =
        body
        |> Envelope.from_binary!()
        |> Envelope.event()

      assert List.first(event.exception)["type"] == "Sentry.CrashError"
      assert List.first(event.exception)["value"] =~ "** (EXIT) time out"
      assert List.first(event.exception)["value"] =~ "GenServer\.call"

      assert conn.request_path == "/api/1/envelope/"
      assert conn.method == "POST"
      send(self_pid, "API called")
      Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
    end)

    modify_env(:sentry, dsn: "http://public:secret@localhost:#{bypass.port}/1")

    {:ok, pid1} = Sentry.TestGenServer.start_link(self_pid)

    capture_log(fn ->
      Task.start(fn ->
        GenServer.call(pid1, {:sleep, 20}, 1)
      end)

      assert_receive "API called"
    end)
  end

  test "only sends one error when a Plug process when configured to exclude cowboy domain" do
    Logger.configure_backend(Sentry.LoggerBackend, excluded_domains: [:cowboy])
    bypass = Bypass.open()
    pid = self()
    modify_env(:sentry, dsn: "http://public:secret@localhost:#{bypass.port}/1")

    {:ok, _plug_pid} = Plug.Cowboy.http(Sentry.ExamplePlugApplication, [], port: 8003)

    Bypass.expect_once(bypass, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      _event =
        body
        |> Envelope.from_binary!()
        |> Envelope.event()

      send(pid, "API called")
      Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
    end)

    capture_log(fn ->
      :hackney.get("http://127.0.0.1:8003/error_route", [], "", [])
      assert_receive "API called"
      refute_receive "API called"
    end)
  after
    :ok = Plug.Cowboy.shutdown(Sentry.ExamplePlugApplication.HTTP)
  end

  test "sends two errors when a Plug process crashes if cowboy domain is not excluded" do
    Logger.configure_backend(Sentry.LoggerBackend, excluded_domains: [])
    bypass = Bypass.open()
    pid = self()
    modify_env(:sentry, dsn: "http://public:secret@localhost:#{bypass.port}/1")

    {:ok, _plug_pid} = Plug.Cowboy.http(Sentry.ExamplePlugApplication, [], port: 8003)

    Bypass.expect(bypass, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      _event =
        body
        |> Envelope.from_binary!()
        |> Envelope.event()

      send(pid, "API called")
      Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
    end)

    capture_log(fn ->
      :hackney.get("http://127.0.0.1:8003/error_route", [], "", [])
      assert_receive "API called"
      assert_receive "API called"
    end)
  after
    :ok = Plug.Cowboy.shutdown(Sentry.ExamplePlugApplication.HTTP)
    Logger.configure_backend(Sentry.LoggerBackend, excluded_domains: [:cowboy])
  end

  test "ignores log messages with excluded domains" do
    Logger.configure_backend(Sentry.LoggerBackend,
      capture_log_messages: true,
      excluded_domains: [:test_domain]
    )

    bypass = Bypass.open()
    modify_env(:sentry, dsn: "http://public:secret@localhost:#{bypass.port}/1")
    pid = self()

    Bypass.expect(bypass, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      event =
        body
        |> Envelope.from_binary!()
        |> Envelope.event()

      send(pid, event.message)
      Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
    end)

    capture_log(fn ->
      Logger.error("no domain")
      Logger.error("test_domain", domain: [:test_domain])
      assert_receive("no domain")
      refute_receive("test_domain")
    end)
  end

  test "includes Logger.metadata for keys configured to be included" do
    Logger.configure_backend(Sentry.LoggerBackend, metadata: [:string, :number, :map, :list])
    bypass = Bypass.open()
    Process.flag(:trap_exit, true)
    pid = self()

    Bypass.expect(bypass, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      event =
        body
        |> Envelope.from_binary!()
        |> Envelope.event()

      assert event.extra["logger_metadata"]["string"] == "string"
      assert event.extra["logger_metadata"]["map"] == %{"a" => "b"}
      assert event.extra["logger_metadata"]["list"] == [1, 2, 3]
      assert event.extra["logger_metadata"]["number"] == 43
      send(pid, "API called")
      Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
    end)

    modify_env(:sentry, dsn: "http://public:secret@localhost:#{bypass.port}/1")

    capture_log(fn ->
      {:ok, pid} = Sentry.TestGenServer.start_link(pid)
      Sentry.TestGenServer.add_logger_metadata(pid, :string, "string")
      Sentry.TestGenServer.add_logger_metadata(pid, :number, 43)
      Sentry.TestGenServer.add_logger_metadata(pid, :map, %{a: "b"})
      Sentry.TestGenServer.add_logger_metadata(pid, :list, [1, 2, 3])
      Sentry.TestGenServer.invalid_function(pid)
      assert_receive "terminating"
      assert_receive "API called"
    end)
  end

  test "does not include Logger.metadata when disabled" do
    Logger.configure_backend(Sentry.LoggerBackend, metadata: [])
    bypass = Bypass.open()
    Process.flag(:trap_exit, true)
    pid = self()

    Bypass.expect(bypass, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      event =
        body
        |> Envelope.from_binary!()
        |> Envelope.event()

      assert event.extra["logger_metadata"] == %{}
      send(pid, "API called")
      Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
    end)

    modify_env(:sentry, dsn: "http://public:secret@localhost:#{bypass.port}/1")

    capture_log(fn ->
      {:ok, pid} = Sentry.TestGenServer.start_link(pid)
      Sentry.TestGenServer.add_logger_metadata(pid, :string, "string")
      Sentry.TestGenServer.add_logger_metadata(pid, :atom, :atom)
      Sentry.TestGenServer.add_logger_metadata(pid, :number, 43)
      Sentry.TestGenServer.add_logger_metadata(pid, :list, [])
      Sentry.TestGenServer.invalid_function(pid)
      assert_receive "terminating"
      assert_receive "API called"
    end)
  end

  test "sends all messages if capture_log_messages is true" do
    Logger.configure_backend(Sentry.LoggerBackend, capture_log_messages: true)
    bypass = Bypass.open()
    modify_env(:sentry, dsn: "http://public:secret@localhost:#{bypass.port}/1")
    pid = self()

    Bypass.expect_once(bypass, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      event =
        body
        |> Envelope.from_binary!()
        |> Envelope.event()

      assert event.message == "testing"
      send(pid, "API called")
      Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
    end)

    capture_log(fn ->
      Logger.error("testing")
      assert_receive("API called")
    end)
  after
    Logger.configure_backend(Sentry.LoggerBackend, capture_log_messages: false)
  end

  test "sends warning messages when configured to :warn" do
    Logger.configure_backend(Sentry.LoggerBackend, level: :warn, capture_log_messages: true)
    bypass = Bypass.open()
    modify_env(:sentry, dsn: "http://public:secret@localhost:#{bypass.port}/1")
    pid = self()

    Bypass.expect_once(bypass, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      event =
        body
        |> Envelope.from_binary!()
        |> Envelope.event()

      assert event.message == "testing"
      assert event.user["user_id"] == 3
      send(pid, "API called")
      Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
    end)

    capture_log(fn ->
      Sentry.Context.set_user_context(%{user_id: 3})
      Logger.warn("testing")
      assert_receive("API called")
    end)
  after
    Logger.configure_backend(Sentry.LoggerBackend, level: :error, capture_log_messages: false)
  end

  test "does not send debug messages when configured to :error" do
    Logger.configure_backend(Sentry.LoggerBackend, capture_log_messages: true)
    bypass = Bypass.open()
    modify_env(:sentry, dsn: "http://public:secret@localhost:#{bypass.port}/1")
    pid = self()

    Bypass.expect_once(bypass, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      event =
        body
        |> Envelope.from_binary!()
        |> Envelope.event()

      assert event.message == "error"
      send(pid, "API called")
      Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
    end)

    capture_log(fn ->
      Sentry.Context.set_user_context(%{user_id: 3})
      Logger.error("error")
      Logger.debug("debug")
      assert_receive("API called")
      refute_receive("API called")
    end)
  after
    Logger.configure_backend(Sentry.LoggerBackend, level: :error, capture_log_messages: false)
  end

  test "sentry metadata is retrieved from callers" do
    Logger.configure_backend(Sentry.LoggerBackend, capture_log_messages: true)
    bypass = Bypass.open()
    modify_env(:sentry, dsn: "http://public:secret@localhost:#{bypass.port}/1")
    pid = self()

    Bypass.expect_once(bypass, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      event =
        body
        |> Envelope.from_binary!()
        |> Envelope.event()

      assert event.user["user_id"] == 3
      assert event.message == "(RuntimeError oops)"
      send(pid, "API called")
      Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
    end)

    capture_log(fn ->
      Sentry.Context.set_user_context(%{user_id: 3})

      {:ok, task} = Task.start_link(__MODULE__, :task, [pid])
      send(task, :go)

      assert_receive("API called")
    end)
  end

  test "sentry extra context is retrieved from callers" do
    Logger.configure_backend(Sentry.LoggerBackend, capture_log_messages: true)
    bypass = Bypass.open()
    modify_env(:sentry, dsn: "http://public:secret@localhost:#{bypass.port}/1")
    pid = self()

    Bypass.expect_once(bypass, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      event =
        body
        |> Envelope.from_binary!()
        |> Envelope.event()

      assert event.extra["day_of_week"] == "Friday"
      assert event.message == "(RuntimeError oops)"
      send(pid, "API called")
      Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
    end)

    capture_log(fn ->
      Sentry.Context.set_extra_context(%{day_of_week: "Friday"})

      {:ok, task} = Task.start_link(__MODULE__, :task, [pid])
      send(task, :go)

      assert_receive("API called")
    end)
  end

  test "handles malformed :callers metadata" do
    Logger.configure_backend(Sentry.LoggerBackend, capture_log_messages: true)
    bypass = Bypass.open()
    modify_env(:sentry, dsn: "http://public:secret@localhost:#{bypass.port}/1")
    pid = self()
    {:ok, dead_pid} = Task.start(fn -> nil end)

    Bypass.expect_once(bypass, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      event =
        body
        |> Envelope.from_binary!()
        |> Envelope.event()

      assert event.message == "error"
      send(pid, "API called")
      Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
    end)

    capture_log(fn ->
      Logger.error("error", callers: [dead_pid, nil])

      assert_receive("API called")
    end)
  end

  test "sets event level to Logger message level" do
    Logger.configure_backend(Sentry.LoggerBackend, level: :warn, capture_log_messages: true)
    bypass = Bypass.open()
    modify_env(:sentry, dsn: "http://public:secret@localhost:#{bypass.port}/1")
    pid = self()

    Bypass.expect_once(bypass, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      event =
        body
        |> Envelope.from_binary!()
        |> Envelope.event()

      assert event.message == "warn"
      assert event.level == "warning"
      send(pid, "API called")
      Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
    end)

    capture_log(fn ->
      Logger.warn("warn")

      assert_receive("API called")
    end)
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
