defmodule RavenTest do
  use ExUnit.Case

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

    assert %Raven.Event{
      culprit: "RavenTest.MyGenServer.handle_call/3",
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
        frames: [
          %{filename: "test/raven_test.exs", function: "RavenTest.MyGenServer.handle_call/3", in_app: true},
          %{filename: "gen_server.erl", function: ":gen_server.try_handle_call/4", in_app: false},
          %{filename: "gen_server.erl", function: ":gen_server.handle_msg/5", in_app: false},
          %{filename: "proc_lib.erl", function: ":proc_lib.init_p_do_apply/3", in_app: false}
        ]
      }
    } = receive_transform
  end

  test "parses GenEvent crashes" do
    {:ok, pid} = GenEvent.start()
    :ok = GenEvent.add_handler(pid, MyGenEvent, :ok)
    GenEvent.call(pid, MyGenEvent, :error)

    assert %Raven.Event{
      culprit: "RavenTest.MyGenEvent.handle_call/2",
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
        frames: [
          %{filename: "test/raven_test.exs", function: "RavenTest.MyGenEvent.handle_call/2", in_app: true},
          %{filename: "lib/gen_event.ex", function: "GenEvent.do_handler/3", in_app: false}
          | _
        ]
      }
    } = receive_transform
  end

  test "parses Task crashes" do
    {:ok, pid} = Task.start_link(__MODULE__, :task, [self()])
    ref = Process.monitor(pid)
    send(pid, :go)
    receive do: ({:DOWN, ^ref, _, _, _} -> :ok)

    assert %Raven.Event{
      culprit: "anonymous fn/0 in RavenTest.task/1",
      exception: [
        %{type: "RuntimeError", value: "oops"}
      ],
      level: "error",
      message: "(RuntimeError) oops",
      platform: "elixir", 
      stacktrace: %{
        frames: [
          %{filename: "test/raven_test.exs", function: "anonymous fn/0 in RavenTest.task/1", in_app: true},
          %{filename: "lib/task/supervised.ex", function: "Task.Supervised.do_apply/2", in_app: false},
          %{filename: "proc_lib.erl", function: ":proc_lib.init_p_do_apply/3", in_app: false}
        ]
      }
    } = receive_transform
  end

  test "parses function crashes" do
    spawn fn -> "a" + 1 end

    assert %Raven.Event{
      culprit: "anonymous fn/0 in RavenTest.test parses function crashes/1",
      level: "error",
      message: "(ArithmeticError) bad argument in arithmetic expression",
      platform: "elixir", 
      stacktrace: %{
        frames: [
          %{filename: "test/raven_test.exs", function: "anonymous fn/0 in RavenTest.test parses function crashes/1", in_app: true}
        ]
      }
    } = receive_transform
  end

  test "does not crash on unknown error" do
    assert %Raven.Event{} = Raven.transform("unknown error of some kind") 
  end

  @sentry_dsn "https://public:secret@app.getsentry.com/1"

  test "parning dsn" do
    assert {"https://app.getsentry.com/api/1/store/", "public", "secret"} = Raven.parse_dsn!(@sentry_dsn)
  end

  test "authorization" do
    {_endpoint, public_key, private_key} = Raven.parse_dsn!(@sentry_dsn)
    assert "Sentry sentry_version=5, sentry_client=raven-elixir/0.0.5, sentry_timestamp=1, sentry_key=public, sentry_secret=secret" == Raven.authorization_header(public_key, private_key, 1)
  end

  def task(parent, fun \\ (fn() -> raise "oops" end)) do
    Process.unlink(parent)
    receive do: (:go -> fun.())
  end

  defp receive_transform do
    receive do
      exception -> Raven.transform(exception)
    end
  end
end
