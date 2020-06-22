defmodule Sentry.LoggerBackendTest do
  use ExUnit.Case
  import ExUnit.CaptureLog
  import Sentry.TestEnvironmentHelper
  require Logger

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
      assert conn.request_path == "/api/1/store/"
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
      json = Jason.decode!(body)

      assert List.first(json["exception"])["value"] ==
               ~s[Erlang error: {:bad_return_value, "I am throwing"}]

      assert conn.request_path == "/api/1/store/"
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
      json = Jason.decode!(body)
      assert List.first(json["exception"])["type"] == "ErlangError"
      assert List.first(json["exception"])["value"] == "Erlang error: :bad_exit"
      assert conn.request_path == "/api/1/store/"
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
      json = Jason.decode!(body)

      assert %{
               "in_app" => false,
               "module" => "Elixir.NaiveDateTime",
               "context_line" => nil,
               "pre_context" => [],
               "post_context" => []
             } = List.last(json["stacktrace"]["frames"])

      assert [%{"test" => "test", "timestamp" => _}] = json["breadcrumbs"]

      assert List.first(json["exception"])["type"] == "FunctionClauseError"
      assert conn.request_path == "/api/1/store/"
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
      json = Jason.decode!(body)
      assert length(json["stacktrace"]["frames"]) == 1

      assert List.first(json["stacktrace"]["frames"])["filename"] ==
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
      json = Jason.decode!(body)

      exception_value =
        List.first(json["exception"])
        |> Map.fetch!("value")

      assert String.contains?(exception_value, "{:timeout, {GenServer, :call")

      assert conn.request_path == "/api/1/store/"
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
      _json = Jason.decode!(body)
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
      _json = Jason.decode!(body)
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

  test "includes Logger.metadata for keys configured to be included" do
    Logger.configure_backend(Sentry.LoggerBackend, metadata: [:string, :number, :map, :list])
    bypass = Bypass.open()
    Process.flag(:trap_exit, true)
    pid = self()

    Bypass.expect(bypass, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      json = Jason.decode!(body)
      assert get_in(json, ["extra", "logger_metadata", "string"]) == "string"
      assert get_in(json, ["extra", "logger_metadata", "map"]) == %{"a" => "b"}
      assert get_in(json, ["extra", "logger_metadata", "list"]) == [1, 2, 3]
      assert get_in(json, ["extra", "logger_metadata", "number"]) == 43
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
      json = Jason.decode!(body)
      assert get_in(json, ["extra", "logger_metadata"]) == %{}
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
      json = Jason.decode!(body)
      assert json["message"] == "testing"
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
      json = Jason.decode!(body)
      assert json["message"] == "testing"
      assert json["user"]["user_id"] == 3
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
      json = Jason.decode!(body)
      assert json["message"] == "error"
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

  # TODO: update for Elixir 1.10.4 to not manually set :callers and replace with Task
  test "sentry metadata is retrieved from callers" do
    Logger.configure_backend(Sentry.LoggerBackend, capture_log_messages: true)
    bypass = Bypass.open()
    modify_env(:sentry, dsn: "http://public:secret@localhost:#{bypass.port}/1")
    pid = self()

    Bypass.expect_once(bypass, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      json = Jason.decode!(body)
      assert json["user"]["user_id"] == 3
      assert json["message"] == "error"
      send(pid, "API called")
      Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
    end)

    capture_log(fn ->
      Sentry.Context.set_user_context(%{user_id: 3})
      parent = self()

      Task.start(fn ->
        Logger.error("error", callers: [parent])
      end)

      assert_receive("API called")
    end)
  end
end
