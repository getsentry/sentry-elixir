defmodule Sentry.LoggerBackendTest do
  use ExUnit.Case
  import ExUnit.CaptureLog
  import Sentry.TestEnvironmentHelper

  setup do
    {:ok, _} = Logger.add_backend(Sentry.LoggerBackend)

    ExUnit.Callbacks.on_exit(fn ->
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
      json = Poison.decode!(body)

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
      json = Poison.decode!(body)
      assert List.first(json["exception"])["type"] == "Elixir.ErlangError"
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
      json = Poison.decode!(body)

      assert %{
               "in_app" => false,
               "module" => "Elixir.NaiveDateTime",
               "context_line" => nil,
               "pre_context" => [],
               "post_context" => []
             } = List.last(json["stacktrace"]["frames"])

      assert List.first(json["exception"])["type"] == "Elixir.FunctionClauseError"
      assert conn.request_path == "/api/1/store/"
      assert conn.method == "POST"
      send(self_pid, "API called")
      Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
    end)

    modify_env(:sentry, dsn: "http://public:secret@localhost:#{bypass.port}/1")

    capture_log(fn ->
      {:ok, pid} = Sentry.TestGenServer.start_link(self_pid)
      Sentry.TestGenServer.invalid_function(pid)
      assert_receive "terminating"
      assert_receive "API called"
    end)
  end

  test "captures errors from spawn() in Plug app" do
    bypass = Bypass.open()
    pid = self()

    Bypass.expect(bypass, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      json = Poison.decode!(body)
      assert length(json["stacktrace"]["frames"]) == 1
      assert List.first(json["stacktrace"]["frames"])["filename"] == "test/support/test_plug.ex"
      send(pid, "API called")
      Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
    end)

    modify_env(:sentry, dsn: "http://public:secret@localhost:#{bypass.port}/1")

    capture_log(fn ->
      Plug.Test.conn(:get, "/spawn_error_route")
      |> Sentry.ExampleApp.call([])

      assert_receive "API called"
    end)
  end
end
