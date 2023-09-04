defmodule Sentry.LoggerHandlerTest do
  use ExUnit.Case, async: false

  import Sentry.TestEnvironmentHelper

  alias Sentry.TestGenServer

  require Logger

  @moduletag :capture_log

  @handler_name :sentry_handler

  setup context do
    if Map.has_key?(context, :bypass) do
      bypass = Bypass.open()
      modify_env(:sentry, dsn: "http://public:secret@localhost:#{bypass.port}/1")
      %{bypass: bypass}
    else
      %{}
    end
  end

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

  test "skips logs if the domain is excluded" do
    add_handler(%{excluded_domains: [:plug, :phoenix]})
    Logger.error("Error message", domain: [:phoenix, :broadway])
  end

  @tag :bypass
  test "reports exceptions", %{bypass: bypass} do
    add_handler(%{})

    Process.flag(:trap_exit, true)

    bypass_ref =
      expect_request(bypass, fn event ->
        assert %{
                 exception: [
                   %{
                     "type" => "RuntimeError",
                     "value" => "unique error",
                     "stacktrace" => %{
                       "frames" => [
                         %{"module" => "Elixir.Task.Supervised"} | _rest
                       ]
                     }
                   }
                 ]
               } = event
      end)

    Task.start(fn ->
      raise "unique error"
    end)

    assert_receive ^bypass_ref
  end

  @tag :bypass
  test "reports non-exception crashes", %{bypass: bypass} do
    add_handler(%{})

    self_pid = self()
    Process.flag(:trap_exit, true)

    bypass_ref =
      expect_request(bypass, fn event ->
        assert List.first(event.exception)["value"] ==
                 ~s[** (exit) bad return value: "I am throwing"]
      end)

    {:ok, pid} = TestGenServer.start_link(self_pid)
    TestGenServer.throw(pid)
    assert_receive "terminating"
    assert_receive ^bypass_ref
  end

  @tag :bypass
  test "abnormal GenServer exit makes call to Sentry API", %{bypass: bypass} do
    add_handler(%{})
    self_pid = self()
    Process.flag(:trap_exit, true)

    bypass_ref =
      expect_request(bypass, fn event ->
        assert List.first(event.exception)["type"] == "Sentry.CrashError"
        assert List.first(event.exception)["value"] == "** (exit) :bad_exit"
      end)

    {:ok, pid} = TestGenServer.start_link(self_pid)
    TestGenServer.exit(pid)
    assert_receive "terminating"
    assert_receive ^bypass_ref
  end

  @tag :bypass
  test "bad function call causing GenServer crash makes call to Sentry API", %{bypass: bypass} do
    add_handler(%{})
    self_pid = self()
    Process.flag(:trap_exit, true)

    bypass_ref =
      expect_request(bypass, fn event ->
        assert %{
                 "in_app" => false,
                 "module" => "Elixir.NaiveDateTime",
                 "context_line" => nil,
                 "pre_context" => [],
                 "post_context" => []
               } = List.last(List.first(event.exception)["stacktrace"]["frames"])

        assert [%{"timestamp" => _, "message" => "test"}] = event.breadcrumbs

        assert List.first(event.exception)["type"] == "FunctionClauseError"
      end)

    {:ok, pid} = TestGenServer.start_link(self_pid)

    TestGenServer.add_sentry_breadcrumb(pid, %{message: "test"})
    TestGenServer.invalid_function(pid)
    assert_receive "terminating"
    assert_receive ^bypass_ref
  end

  @tag :bypass
  test "captures errors from spawn() in Plug app", %{bypass: bypass} do
    add_handler(%{})

    bypass_ref =
      expect_request(bypass, fn event ->
        assert length(List.first(event.exception)["stacktrace"]["frames"]) == 1

        assert List.first(List.first(event.exception)["stacktrace"]["frames"])["filename"] ==
                 "test/support/example_plug_application.ex"
      end)

    Plug.Test.conn(:get, "/spawn_error_route")
    |> Sentry.ExamplePlugApplication.call([])

    assert_receive ^bypass_ref
  end

  @tag :bypass
  test "GenServer timeout makes call to Sentry API", %{bypass: bypass} do
    add_handler(%{})
    self_pid = self()
    Process.flag(:trap_exit, true)

    bypass_ref =
      expect_request(bypass, fn event ->
        assert List.first(event.exception)["type"] == "Sentry.CrashError"
        assert List.first(event.exception)["value"] =~ "** (EXIT) time out"
        assert List.first(event.exception)["value"] =~ "GenServer\.call"
      end)

    {:ok, pid1} = TestGenServer.start_link(self_pid)

    Task.start(fn ->
      GenServer.call(pid1, {:sleep, 20}, 0)
    end)

    assert_receive ^bypass_ref
  end

  @tag :bypass
  test "only sends one error when a Plug process when configured to exclude cowboy domain",
       %{bypass: bypass} do
    add_handler(%{excluded_domains: [:cowboy]})

    {:ok, _plug_pid} = Plug.Cowboy.http(Sentry.ExamplePlugApplication, [], port: 8003)

    bypass_ref = expect_request(bypass, fn _event -> nil end)

    :hackney.get("http://127.0.0.1:8003/error_route", [], "", [])
    assert_receive ^bypass_ref
    refute_receive "API called"
  after
    :ok = Plug.Cowboy.shutdown(Sentry.ExamplePlugApplication.HTTP)
  end

  @tag :bypass
  test "sends two errors when a Plug process crashes if cowboy domain is not excluded",
       %{bypass: bypass} do
    add_handler(%{excluded_domains: []})

    {:ok, _plug_pid} = Plug.Cowboy.http(Sentry.ExamplePlugApplication, [], port: 8003)

    bypass_ref = expect_request(bypass, fn _event -> nil end)

    :hackney.get("http://127.0.0.1:8003/error_route", [], "", [])
    assert_receive ^bypass_ref
    assert_receive ^bypass_ref
  after
    :ok = Plug.Cowboy.shutdown(Sentry.ExamplePlugApplication.HTTP)
  end

  @tag :bypass
  test "sends all messages if capture_log_messages is true", %{bypass: bypass} do
    add_handler(%{capture_log_messages: true})

    bypass_ref =
      expect_request(bypass, fn event ->
        assert event.message == "testing"
      end)

    Logger.error("testing")
    assert_receive ^bypass_ref
  end

  @tag :bypass
  test "does not include Logger metadata when disabled", %{bypass: bypass} do
    add_handler(%{})
    Process.flag(:trap_exit, true)
    pid = self()

    bypass_ref =
      expect_request(bypass, fn event ->
        assert event.extra["logger_metadata"] == %{}
      end)

    {:ok, pid} = TestGenServer.start_link(pid)
    TestGenServer.add_logger_metadata(pid, :string, "string")
    TestGenServer.add_logger_metadata(pid, :atom, :atom)
    TestGenServer.add_logger_metadata(pid, :number, 43)
    TestGenServer.add_logger_metadata(pid, :list, [])
    TestGenServer.invalid_function(pid)
    assert_receive "terminating"
    assert_receive ^bypass_ref
  end

  @tag :bypass
  test "includes Logger.metadata for keys configured to be included", %{bypass: bypass} do
    add_handler(%{metadata: [:string, :number, :map, :list]})

    Process.flag(:trap_exit, true)
    pid = self()

    bypass_ref =
      expect_request(bypass, fn event ->
        assert event.extra["logger_metadata"]["string"] == "string"
        assert event.extra["logger_metadata"]["map"] == %{"a" => "b"}
        assert event.extra["logger_metadata"]["list"] == [1, 2, 3]
        assert event.extra["logger_metadata"]["number"] == 43
      end)

    {:ok, pid} = TestGenServer.start_link(pid)
    TestGenServer.add_logger_metadata(pid, :string, "string")
    TestGenServer.add_logger_metadata(pid, :number, 43)
    TestGenServer.add_logger_metadata(pid, :map, %{a: "b"})
    TestGenServer.add_logger_metadata(pid, :list, [1, 2, 3])
    TestGenServer.invalid_function(pid)
    assert_receive "terminating"
    assert_receive ^bypass_ref
  end

  @tag :bypass
  test "sets event level to Logger message level", %{bypass: bypass} do
    add_handler(%{level: :warning, capture_log_messages: true})

    bypass_ref =
      expect_request(bypass, fn event ->
        assert event.message == "warn"
        assert event.level == "warning"
      end)

    Logger.log(:warning, "warn")
    assert_receive ^bypass_ref
  end

  @tag :bypass
  test "sentry metadata is retrieved from callers", %{bypass: bypass} do
    add_handler(%{capture_log_messages: true})

    pid = self()

    bypass_ref =
      expect_request(bypass, fn event ->
        assert event.user["user_id"] == 3
        assert List.first(event.exception)["type"] == "RuntimeError"
        assert List.first(event.exception)["value"] == "oops"
      end)

    Sentry.Context.set_user_context(%{user_id: 3})

    {:ok, task} = Task.start_link(__MODULE__, :task, [pid])
    send(task, :go)

    assert_receive ^bypass_ref
  end

  @tag :bypass
  test "sentry extra context is retrieved from callers", %{bypass: bypass} do
    add_handler(%{capture_log_messages: true})

    pid = self()

    bypass_ref =
      expect_request(bypass, fn event ->
        assert event.extra["day_of_week"] == "Friday"
        assert List.first(event.exception)["type"] == "RuntimeError"
        assert List.first(event.exception)["value"] == "oops"
      end)

    Sentry.Context.set_extra_context(%{day_of_week: "Friday"})

    {:ok, task} = Task.start_link(__MODULE__, :task, [pid])
    send(task, :go)

    assert_receive ^bypass_ref
  end

  @tag :bypass
  test "handles malformed :callers metadata", %{bypass: bypass} do
    add_handler(%{capture_log_messages: true})

    {:ok, dead_pid} = Task.start(fn -> nil end)

    bypass_ref =
      expect_request(bypass, fn event ->
        assert event.message == "error"
      end)

    Logger.error("error", callers: [dead_pid, nil])

    assert_receive ^bypass_ref
  end

  defp add_handler(config) do
    assert :ok = :logger.add_handler(@handler_name, Sentry.LoggerHandler, %{config: config})
  end

  defp expect_request(bypass, assertions_fun) do
    parent = self()
    ref = make_ref()

    Bypass.expect(bypass, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/api/1/envelope/"
      assert {:ok, body, conn} = Plug.Conn.read_body(conn)
      event = TestHelpers.decode_event_from_envelope!(body)

      assertions_fun.(event)
      send(parent, ref)
      Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
    end)

    ref
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
