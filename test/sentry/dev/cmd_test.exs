defmodule Sentry.Dev.CmdTest do
  use ExUnit.Case, async: true

  alias Sentry.Dev.Cmd

  defp tmp_path(suffix) do
    path =
      Path.join(System.tmp_dir!(), "cmd_test_#{System.unique_integer([:positive])}_#{suffix}")

    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  describe "command/4" do
    test "returns {:ok, output} for a successful command" do
      assert {:ok, output} = Cmd.command("sh", ".", ["-c", "echo hello"])
      assert output =~ "hello"
    end

    test "returns {:error, status, output} for a failing command" do
      assert {:error, status, output} = Cmd.command("sh", ".", ["-c", "echo boom >&2; exit 3"])
      assert status == 3
      # stderr is merged into the captured output.
      assert output =~ "boom"
    end

    test "passes env vars through to the subprocess" do
      assert {:ok, output} =
               Cmd.command("sh", ".", ["-c", "echo $MARKER"], env: [{"MARKER", "from-env"}])

      assert output =~ "from-env"
    end

    test "runs in the given directory" do
      dir = tmp_path("cwd")
      File.mkdir_p!(dir)

      assert {:ok, output} = Cmd.command("pwd", dir, [])
      assert output |> String.trim() |> Path.expand() == Path.expand(dir)
    end

    test "writes the captured output to :log_to" do
      log = tmp_path("out.log")

      assert {:ok, _} = Cmd.command("sh", ".", ["-c", "echo logged"], log_to: log)

      contents = File.read!(log)
      assert contents =~ "logged"
      assert contents =~ "exit 0"
    end

    test "on timeout it returns :timeout AND kills the subprocess" do
      # The child writes `started`, sleeps, then writes `finished`. We time out during
      # the sleep. If the subprocess is properly killed, `finished` is never written; if
      # it leaks (the old Task.shutdown behavior), `finished` appears once the sleep ends.
      started = tmp_path("started")
      finished = tmp_path("finished")

      script = "touch #{started}; sleep 2; touch #{finished}"

      assert {:error, :timeout, output} = Cmd.command("sh", ".", ["-c", script], timeout: 1)
      assert output =~ "killed"

      # The process had time to start before the timeout fired.
      assert File.exists?(started)

      # Wait past the child's sleep; a killed process never reaches the second `touch`.
      Process.sleep(2_500)
      refute File.exists?(finished), "subprocess was not killed on timeout (it leaked)"
    end

    test "a command that finishes within the timeout is unaffected" do
      assert {:ok, output} = Cmd.command("sh", ".", ["-c", "echo quick"], timeout: 30)
      assert output =~ "quick"
    end
  end
end
