defmodule Sentry.LoggerHandlerTest do
  use Sentry.Case, async: false

  import Sentry.TestHelpers

  alias Sentry.TestGenServer

  require Logger

  @moduletag :capture_log

  # This test is problematic on Elixir 1.14 and lower because of issues with logs
  # spilling due to a race condition that was fixed in 1.15+.
  if Version.match?(System.version(), "< 1.15.4") do
    @moduletag :skip
  end

  @handler_name :sentry_handler

  setup :register_before_send
  setup :add_handler

  setup do
    on_exit(fn ->
      for %{id: id, module: module} <- :logger.get_handler_config(),
          function_exported?(module, :filesync, 1) do
        try do
          module.filesync(id)
        catch
          _, _ -> :ok
        end
      end
    end)
  end

  test "skips logs from a lower level than the configured one" do
    # Default level is :error, so this doesn't get reported.
    Logger.warning("Warning message")

    # Change the level to :info and make sure that :debug messages are not reported.
    assert :ok = :logger.update_handler_config(@handler_name, :level, :info)

    on_exit(fn ->
      :logger.update_handler_config(@handler_name, :level, :error)
    end)

    Logger.debug("Debug message")
  end

  test "a logged raised exception is reported", %{sender_ref: ref} do
    Task.start(fn ->
      raise "Unique Error"
    end)

    assert_receive {^ref, event}
    assert [exception] = event.exception
    assert exception.type == "RuntimeError"
    assert exception.value == "Unique Error"
  end

  test "retrieves context from :callers", %{sender_ref: ref} do
    Sentry.Context.set_extra_context(%{day_of_week: "Friday"})
    Sentry.Context.set_user_context(%{user_id: 3})

    {:ok, _task_pid} = Task.start(fn -> raise "oops" end)

    assert_receive {^ref, event}

    assert event.user.user_id == 3
    assert event.extra.day_of_week == "Friday"
    assert [exception] = event.exception
    assert exception.type == "RuntimeError"
    assert exception.value == "oops"
  end

  describe "with Plug" do
    if System.otp_release() < "26", do: @describetag(:skip)

    @tag handler_config: %{excluded_domains: []}
    test "captures errors from spawn/0 in Plug app", %{sender_ref: ref} do
      :get
      |> Plug.Test.conn("/spawn_error_route")
      |> Plug.run([{Sentry.ExamplePlugApplication, []}])

      assert_receive {^ref, event}

      assert [stacktrace_frame] = hd(event.exception).stacktrace.frames
      assert stacktrace_frame.filename == "test/support/example_plug_application.ex"
    end

    @tag handler_config: %{excluded_domains: []}
    test "sends two errors when a Plug process crashes if cowboy domain is not excluded",
         %{sender_ref: ref} do
      {:ok, _plug_pid} = Plug.Cowboy.http(Sentry.ExamplePlugApplication, [], port: 8003)

      :hackney.get("http://127.0.0.1:8003/error_route", [], "", [])
      assert_receive {^ref, _event}, 1000
    after
      :ok = Plug.Cowboy.shutdown(Sentry.ExamplePlugApplication.HTTP)
    end
  end

  describe "with capture_log_messages: true" do
    @tag handler_config: %{capture_log_messages: true}
    test "sends error messages by default", %{sender_ref: ref} do
      Logger.error("Testing error")
      Logger.info("Testing info")

      assert_receive {^ref, event}
      assert event.message == "Testing error"

      refute_receive {^ref, _event}, 100
    end

    @tag handler_config: %{capture_log_messages: true, level: :warning}
    test "respects the configured :level", %{sender_ref: ref} do
      Logger.log(:warning, "Testing warning")
      Logger.log(:info, "Testing info")

      assert_receive {^ref, event}

      assert event.message == "Testing warning"
      assert event.level == :warning

      refute_receive {^ref, _event}, 100
    end

    @tag handler_config: %{capture_log_messages: true}
    test "handles malformed :callers metadata", %{sender_ref: ref} do
      dead_pid = spawn(fn -> :ok end)

      Logger.error("Error", callers: [dead_pid, nil])

      assert_receive {^ref, event}
      assert event.message == "Error"
    end

    @tag handler_config: %{capture_log_messages: true, excluded_domains: [:test_domain]}
    test "ignores log messages with excluded domains", %{sender_ref: ref} do
      Logger.error("no domain")
      Logger.error("test_domain", domain: [:test_domain])

      assert_receive {^ref, event}
      assert event.message == "no domain"
    end

    @tag handler_config: %{capture_log_messages: true}
    test "ignores log messages that are logged by Sentry itself", %{sender_ref: ref} do
      Logger.error("Sentry had an error", domain: [:sentry])
      refute_receive {^ref, _event}
    end
  end

  describe "with a crashing GenServer" do
    setup do
      %{test_genserver: start_supervised!(TestGenServer, restart: :temporary)}
    end

    test "a GenServer throw is reported", %{sender_ref: ref, test_genserver: test_genserver} do
      run_and_catch_exit(test_genserver, fn ->
        throw(:testing_throw)
      end)

      assert_receive {^ref, event}
      assert event.message =~ "** (stop) bad return value: :testing_throw"
    end

    test "abnormal GenServer exit is reported", %{sender_ref: ref, test_genserver: test_genserver} do
      run_and_catch_exit(test_genserver, fn ->
        {:stop, :bad_exit, :no_state}
      end)

      assert_receive {^ref, event}

      assert event.message =~ "** (stop) :bad_exit"

      if System.otp_release() >= "26" do
        assert [] = event.exception
        assert [_thread] = event.threads
      end
    end

    @tag handler_config: %{metadata: [:string, :number, :map, :list, :chardata]}
    test "includes Logger metadata for keys configured to be included",
         %{sender_ref: ref, test_genserver: test_genserver} do
      run_and_catch_exit(test_genserver, fn ->
        Logger.metadata(
          string: "string",
          number: 43,
          map: %{a: "b"},
          list: [1, 2, 3],
          chardata: ["π's unicode is", ?\s, [?π]]
        )

        invalid_function()
      end)

      assert_receive {^ref, event}
      assert event.extra.logger_metadata.string == "string"
      assert event.extra.logger_metadata.map == %{a: "b"}
      assert event.extra.logger_metadata.list == [1, 2, 3]
      assert event.extra.logger_metadata.number == 43
      assert event.extra.logger_metadata.chardata == "π's unicode is π"
    end

    @tag handler_config: %{metadata: []}
    test "does not include Logger metadata when disabled",
         %{sender_ref: ref, test_genserver: test_genserver} do
      run_and_catch_exit(test_genserver, fn ->
        Logger.metadata(
          string: "string",
          number: 43,
          map: %{a: "b"},
          list: [1, 2, 3]
        )

        invalid_function()
      end)

      assert_receive {^ref, event}
      assert event.extra.logger_metadata == %{}
    end

    @tag handler_config: %{metadata: :all}
    test "supports :all for Logger metadata", %{sender_ref: ref, test_genserver: test_genserver} do
      run_and_catch_exit(test_genserver, fn ->
        Logger.metadata(my_string: "some string")
        invalid_function()
      end)

      assert_receive {^ref, event}

      assert event.extra.logger_metadata.my_string == "some string"
      assert event.extra.logger_metadata.domain == [:otp]
      assert is_integer(event.extra.logger_metadata.time)
      assert is_pid(event.extra.logger_metadata.pid)

      if System.otp_release() >= "26" do
        assert {%FunctionClauseError{}, _stacktrace} = event.extra.logger_metadata.crash_reason
      end

      # Make sure that all this stuff is serializable.
      assert Sentry.Client.render_event(event).extra.logger_metadata.pid =~ "#PID<"
    end

    test "bad function call causing GenServer crash is reported",
         %{sender_ref: ref, test_genserver: test_genserver} do
      run_and_catch_exit(test_genserver, fn ->
        Sentry.Context.add_breadcrumb(%{message: "test"})
        invalid_function()
      end)

      assert_receive {^ref, event}

      assert [%{message: "test"}] = event.breadcrumbs

      assert [exception] = event.exception

      assert exception.type == "FunctionClauseError"

      assert %{
               in_app: false,
               module: NaiveDateTime,
               context_line: nil,
               pre_context: [],
               post_context: []
             } = List.last(exception.stacktrace.frames)
    end

    test "GenServer timeout is reported", %{sender_ref: ref, test_genserver: test_genserver} do
      Task.start(fn ->
        TestGenServer.run(test_genserver, fn -> Process.sleep(:infinity) end, _timeout = 0)
      end)

      assert_receive {^ref, event}

      assert [] = event.exception
      assert [thread] = event.threads

      assert event.message =~ "** (stop) exited in: GenServer.call("
      assert event.message =~ "** (EXIT) time out"
      assert length(thread.stacktrace.frames) > 0
    end

    test "reports crashes on c:GenServer.init/1", %{sender_ref: ref} do
      enable_sasl_reports()

      defmodule CrashingGenServerInInit do
        use GenServer
        def init(_args), do: raise("oops")
      end

      assert {:error, _reason_and_stacktrace} = GenServer.start(CrashingGenServerInInit, :no_arg)

      assert_receive {^ref, event}

      assert [exception] = event.exception
      assert exception.type == "RuntimeError"
      assert exception.value == "oops"
    end
  end

  describe "with a crashing :gen_statem" do
    defmodule TestGenStagem do
      @behaviour :gen_statem

      def child_spec(_opts) do
        %{id: __MODULE__, start: {:gen_statem, :start, [__MODULE__, :no_arg, _opts = []]}}
      end

      def run(pid, fun), do: :gen_statem.call(pid, {:run, fun})

      ## Callbacks
      def callback_mode, do: :state_functions
      def init(_arg), do: {:ok, :main_state, %{}}
      def main_state({:call, _from}, {:run, fun}, _data), do: fun.()
    end

    test "needs handle_sasl_reports: true to report crashes", %{sender_ref: ref} do
      enable_sasl_reports()

      pid = start_supervised!(TestGenStagem, restart: :temporary)

      catch_exit(TestGenStagem.run(pid, fn -> raise "oops" end))

      assert_receive {^ref, event}
      assert [exception] = event.exception
      assert exception.type == "RuntimeError"
      assert exception.value == "oops"
    end
  end

  defp register_before_send(_context) do
    pid = self()
    ref = make_ref()

    put_test_config(
      before_send: fn event ->
        send(pid, {ref, event})
        false
      end,
      dsn: "http://public:secret@localhost:9392/1"
    )

    %{sender_ref: ref}
  end

  defp add_handler(context) do
    handler_config =
      case Map.fetch(context, :handler_config) do
        {:ok, config} -> %{config: config}
        :error -> %{}
      end

    assert :ok = :logger.add_handler(@handler_name, Sentry.LoggerHandler, handler_config)

    on_exit(fn ->
      _ = :logger.remove_handler(@handler_name)
    end)
  end

  defp run_and_catch_exit(test_genserver_pid, fun) do
    catch_exit(TestGenServer.run(test_genserver_pid, fun))
  end

  defp invalid_function do
    NaiveDateTime.from_erl({}, {}, {})
  end

  defp enable_sasl_reports do
    Application.stop(:logger)
    Application.put_env(:logger, :handle_sasl_reports, true)
    Application.start(:logger)

    on_exit(fn ->
      Application.stop(:logger)
      Application.put_env(:logger, :handle_sasl_reports, false)
      Application.start(:logger)
    end)
  end
end
