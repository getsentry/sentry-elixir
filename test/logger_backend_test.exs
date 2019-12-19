defmodule Sentry.LoggerBackendTest do
  use ExUnit.Case
  import ExUnit.CaptureLog
  import Sentry.TestEnvironmentHelper

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

      assert List.first(json["exception"])["type"] == "FunctionClauseError"
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
      json = Jason.decode!(body)
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

  test "only sends one error when a Plug process crashes" do
    Code.compile_string("""
      defmodule SentryApp do
        use Plug.Router
        use Plug.ErrorHandler
        use Sentry.Plug
        plug :match
        plug :dispatch
        forward("/", to: Sentry.ExampleApp)
      end
    """)

    bypass = Bypass.open()
    pid = self()
    modify_env(:sentry, dsn: "http://public:secret@localhost:#{bypass.port}/1")

    {:ok, _plug_pid} = Plug.Cowboy.http(SentryApp, [], port: 8003)

    Bypass.expect(bypass, fn conn ->
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
  end

  if :erlang.system_info(:otp_release) >= '21' do
    test "includes Logger.metadata when enabled if the key and value are safely JSON-encodable" do
      Logger.configure_backend(Sentry.LoggerBackend, include_logger_metadata: true)
      bypass = Bypass.open()
      Process.flag(:trap_exit, true)
      pid = self()

      Bypass.expect(bypass, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        json = Jason.decode!(body)
        assert get_in(json, ["extra", "logger_metadata", "string"]) == "string"
        assert get_in(json, ["extra", "logger_metadata", "atom"]) == "atom"
        assert get_in(json, ["extra", "logger_metadata", "number"]) == 43
        refute Map.has_key?(get_in(json, ["extra", "logger_metadata"]), "list")
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

    test "does not include Logger.metadata when disabled" do
      Logger.configure_backend(Sentry.LoggerBackend, include_logger_metadata: false)
      bypass = Bypass.open()
      Process.flag(:trap_exit, true)
      pid = self()

      Bypass.expect(bypass, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        json = Jason.decode!(body)
        refute get_in(json, ["extra", "logger_metadata", "string"]) == "string"
        refute get_in(json, ["extra", "logger_metadata", "atom"]) == "atom"
        refute get_in(json, ["extra", "logger_metadata", "number"]) == 43
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
  end
end
