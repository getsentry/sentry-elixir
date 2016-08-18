defmodule SentryTest do
  use ExUnit.Case, async: true

  defmodule Forwarder do
    use GenEvent

    def handle_call({:configure, options}, _state) do
      {:ok, :ok, options[:pid]}
    end

    def handle_event({:error, gl, {Logger, msg, _ts, _md}}, test_pid) when node(gl) == node() do
      send(test_pid, msg)
      {:ok, test_pid}
    end

    def handle_event(_data, test_pid) do
      {:ok, test_pid}
    end
  end

  defmodule MyGenServer do
    use GenServer

    def handle_call(:error, _, _) do
      raise "oops"
    end
  end

  defmodule MyGenEvent do
    use GenEvent

    def handle_call(:error, _) do
      raise "oops"
    end
  end

  setup do
    Logger.remove_backend(:console)
    Logger.add_backend(Forwarder)
    Logger.configure_backend(Forwarder, pid: self)
    {:ok, []}
  end

  test "parses GenServer crashes" do
    {:ok, pid} = GenServer.start(MyGenServer, :ok)
    catch_exit(GenServer.call(pid, :error))

    assert %Sentry.Event{
      culprit: "SentryTest.MyGenServer.handle_call/3",
      exception: [
        %{type: "RuntimeError", value: "oops"}
      ],
      extra: %{
        last_message: ":error",
        state: ":ok"
      },
      level: "error",
      message: "(RuntimeError) oops",
      platform: "elixir",
      stacktrace: %{
        frames: frames
      }
    } = receive_transform
    assert [
      %{filename: "test/sentry_test.exs", function: "SentryTest.MyGenServer.handle_call/3", in_app: true, lineno: 25},
      %{filename: "gen_server.erl", in_app: false}
    ] = frames |> Enum.reverse |> Enum.take(2)

    Enum.each(frames, fn(f) ->
      assert String.valid?(f.filename)
      assert String.valid?(f.function)
      assert is_integer(f.lineno)
      assert is_boolean(f.in_app)
    end)

  end

  test "parses GenEvent crashes" do
    {:ok, pid} = GenEvent.start()
    :ok = GenEvent.add_handler(pid, MyGenEvent, :ok)
    GenEvent.call(pid, MyGenEvent, :error)

    assert %Sentry.Event{
      culprit: "SentryTest.MyGenEvent.handle_call/2",
      exception: [
        %{type: "RuntimeError", value: "oops"}
      ],
      extra: %{
        last_message: ":error",
        state: ":ok"
      },
      level: "error",
      message: "(RuntimeError) oops",
      platform: "elixir",
      stacktrace: %{
        frames: frames
      }
    } = receive_transform

    assert [
      %{filename: "test/sentry_test.exs", function: "SentryTest.MyGenEvent.handle_call/2", in_app: true},
      %{filename: "lib/gen_event.ex", function: "GenEvent.do_handler/3", in_app: false}
    ] = frames |> Enum.reverse |> Enum.take(2)
  end

  test "parses Task crashes" do
    {:ok, pid} = Task.start_link(__MODULE__, :task, [self()])
    ref = Process.monitor(pid)
    send(pid, :go)
    receive do: ({:DOWN, ^ref, _, _, _} -> :ok)

    assert %Sentry.Event{
      culprit: "anonymous fn/0 in SentryTest.task/1",
      exception: [
        %{type: "RuntimeError", value: "oops"}
      ],
      level: "error",
      message: "(RuntimeError) oops",
      platform: "elixir",
      stacktrace: %{
        frames: [
          %{filename: "proc_lib.erl", function: ":proc_lib.init_p_do_apply/3", in_app: false},
          %{filename: "lib/task/supervised.ex", function: "Task.Supervised.do_apply/2", in_app: false},
          %{filename: "test/sentry_test.exs", function: "anonymous fn/0 in SentryTest.task/1", in_app: true}
        ]
      }
    } = receive_transform
  end

  test "parses function crashes" do
    spawn fn -> raise RuntimeError.exception("failure") end
    assert %Sentry.Event{
      culprit: "anonymous fn/0 in SentryTest.test parses function crashes/1",
      level: "error",
      message: "(RuntimeError) failure",
      platform: "elixir",
      stacktrace: %{
        frames: [
          %{filename: "test/sentry_test.exs", function: "anonymous fn/0 in SentryTest.test parses function crashes/1", in_app: true}
        ]
      }
    } = receive_transform
  end

  test "parses undefined function errors" do
    spawn fn -> Sentry.Event.not_a_function end

    assert %Sentry.Event{
      culprit: nil,
      level: "error",
      message: message,
      platform: "elixir"
    } = receive_transform

    assert Regex.match? ~r/\(UndefinedFunctionError\)|Error in process/, message
  end

  test "does not crash on unknown error" do
    assert %Sentry.Event{} = Sentry.Event.transform_logger_stacktrace("unknown error of some kind")
  end

  def task(parent, fun \\ (fn() -> raise "oops" end)) do
    Process.unlink(parent)
    receive do: (:go -> fun.())
  end

  defp receive_transform do
    receive do
      exception -> Sentry.Event.transform_logger_stacktrace(exception)
    end
  end
end
