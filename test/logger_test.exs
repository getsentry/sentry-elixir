defmodule Sentry.LoggerTest do
  use ExUnit.Case
  import ExUnit.CaptureLog
  import Sentry.TestEnvironmentHelper

  test "exception makes call to Sentry API" do
    bypass = Bypass.open
    pid = self()
    Bypass.expect bypass, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert body =~ "RuntimeError"
      assert body =~ "Unique Error"
      assert conn.request_path == "/api/1/store/"
      assert conn.method == "POST"
      send(pid, "API called")
      Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
    end

    modify_env(:sentry, dsn: "http://public:secret@localhost:#{bypass.port}/1")
    :error_logger.add_report_handler(Sentry.Logger)

    capture_log fn ->
      Task.start( fn ->
        raise "Unique Error"
      end)

      assert_receive "API called"
    end

    :error_logger.delete_report_handler(Sentry.Logger)
  end

  test "GenServer throw makes call to Sentry API" do
    Process.flag :trap_exit, true
    bypass = Bypass.open
    Bypass.expect bypass, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      json = Poison.decode!(body)
      assert List.first(json["exception"])["type"] == "exit"
      assert List.first(json["exception"])["value"] == "** (exit) bad return value: \"I am throwing\""
      assert conn.request_path == "/api/1/store/"
      assert conn.method == "POST"
      Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
    end

    modify_env(:sentry, dsn: "http://public:secret@localhost:#{bypass.port}/1")
    :error_logger.add_report_handler(Sentry.Logger)

    capture_log fn ->
      {:ok, pid} = Sentry.TestGenServer.start_link(self())
      Sentry.TestGenServer.do_throw(pid)
      assert_receive "terminating"
    end
    :error_logger.delete_report_handler(Sentry.Logger)
  end

  test "abnormal GenServer exit makes call to Sentry API" do
    Process.flag :trap_exit, true
    bypass = Bypass.open
    Bypass.expect bypass, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      json = Poison.decode!(body)
      assert List.first(json["exception"])["type"] == "exit"
      assert List.first(json["exception"])["value"] == "** (exit) :bad_exit"
      assert conn.request_path == "/api/1/store/"
      assert conn.method == "POST"
      Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
    end

    modify_env(:sentry, dsn: "http://public:secret@localhost:#{bypass.port}/1")
    :error_logger.add_report_handler(Sentry.Logger)

    capture_log fn ->
      {:ok, pid} = Sentry.TestGenServer.start_link(self())
      Sentry.TestGenServer.bad_exit(pid)
      assert_receive "terminating"
    end
    :error_logger.delete_report_handler(Sentry.Logger)
  end

  test "Bad function call causing GenServer crash makes call to Sentry API" do
    Process.flag :trap_exit, true
    bypass = Bypass.open
    {otp_version, ""} = Float.parse(System.otp_release)

    Bypass.expect bypass, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      json = Poison.decode!(body)
      cond do
         otp_version >= 20.0 ->
          assert List.first(json["exception"])["type"] == "Elixir.FunctionClauseError"
          assert String.starts_with?(List.first(json["exception"])["value"], "no function clause")

        otp_version < 20.0 ->
          assert List.first(json["exception"])["type"] == "exit"
          assert List.first(json["exception"])["value"] == "** (exit) :function_clause"
      end

      cond do
        Version.match?(System.version, "< 1.4.0") ->
          assert List.last(json["stacktrace"]["frames"])["vars"] == %{"arg0" => "{}", "arg1" => "{}"}
          assert List.last(json["stacktrace"]["frames"])["function"] == "NaiveDateTime.from_erl/2"
          assert List.last(json["stacktrace"]["frames"])["filename"] == "lib/calendar.ex"
          assert List.last(json["stacktrace"]["frames"])["lineno"] == 878
        Version.match?(System.version, "< 1.5.0") ->
          assert List.last(json["stacktrace"]["frames"])["vars"] == %{"arg0" => "{}", "arg1" => "{}"}
          assert List.last(json["stacktrace"]["frames"])["function"] == "NaiveDateTime.from_erl/2"
          assert List.last(json["stacktrace"]["frames"])["filename"] == "lib/calendar.ex"
          assert List.last(json["stacktrace"]["frames"])["lineno"] == 1214
        Version.match?(System.version, ">= 1.5.0") ->
          assert List.last(json["stacktrace"]["frames"])["vars"] == %{"arg0" => "{}", "arg1" => "{}", "arg2" => "{}"}
          assert List.last(json["stacktrace"]["frames"])["filename"] == "lib/calendar/naive_datetime.ex"
          assert List.last(json["stacktrace"]["frames"])["function"] == "NaiveDateTime.from_erl/3"
          assert List.last(json["stacktrace"]["frames"])["lineno"] == 522
      end

      assert %{"in_app" => false,
               "module" => "Elixir.NaiveDateTime",
               "context_line" => nil,
               "pre_context" => [],
               "post_context" => []} = List.last(json["stacktrace"]["frames"])
      assert conn.request_path == "/api/1/store/"
      assert conn.method == "POST"
      Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
    end

    modify_env(:sentry, dsn: "http://public:secret@localhost:#{bypass.port}/1")
    :error_logger.add_report_handler(Sentry.Logger)

    capture_log fn ->
      {:ok, pid} = Sentry.TestGenServer.start_link(self())
      Sentry.TestGenServer.invalid_function(pid)
      assert_receive "terminating"
    end
    :error_logger.delete_report_handler(Sentry.Logger)
  end

  test "error_logger passes context properly" do
    bypass = Bypass.open
    pid = self()
    Bypass.expect bypass, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      body = Poison.decode!(body)
      assert get_in(body, ["extra", "fruit"]) == "apples"
      assert conn.request_path == "/api/1/store/"
      assert conn.method == "POST"
      send(pid, "API called")
      Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
    end

    modify_env(:sentry, dsn: "http://public:secret@localhost:#{bypass.port}/1")
    :error_logger.add_report_handler(Sentry.Logger)

    capture_log fn ->
      Task.start( fn ->
        Sentry.Context.set_extra_context(%{fruit: "apples"})
        raise "Unique Error"
      end)

      assert_receive "API called"
    end

    :error_logger.delete_report_handler(Sentry.Logger)
  end
end
