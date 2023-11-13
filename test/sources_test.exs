defmodule Sentry.SourcesTest do
  use ExUnit.Case, async: false
  use Plug.Test

  import Sentry.TestEnvironmentHelper

  describe "load_files/0" do
    test "loads files" do
      paths = [
        File.cwd!() <> "/test/fixtures/example-umbrella-app/apps/app_a",
        File.cwd!() <> "/test/fixtures/example-umbrella-app/apps/app_b"
      ]

      assert {:ok,
              %{
                "lib/module_a.ex" => %{
                  1 => "defmodule ModuleA do",
                  2 => "  def test do",
                  3 => "    \"test a\"",
                  4 => "  end",
                  5 => "end"
                },
                "lib/module_b.ex" => %{
                  1 => "defmodule ModuleB do",
                  2 => "  def test do",
                  3 => "    \"test b\"",
                  4 => "  end",
                  5 => "end"
                }
              }} = Sentry.Sources.load_files(paths)
    end

    test "raises error when two files have the same relative path" do
      paths = [
        File.cwd!() <> "/test/fixtures/example-umbrella-app-with-conflict/apps/app_a",
        File.cwd!() <> "/test/fixtures/example-umbrella-app-with-conflict/apps/app_b"
      ]

      assert {:error, message} = Sentry.Sources.load_files(paths)

      assert message == """
             Found two source files in different source root paths with the same relative path:

               1. test/fixtures/example-umbrella-app-with-conflict/apps/app_b/lib/module_a.ex
               2. test/fixtures/example-umbrella-app-with-conflict/apps/app_a/lib/module_a.ex

             The part of those paths that causes the conflict is:

               lib/module_a.ex

             Sentry cannot report the right source code context if this happens, because
             it won't be able to retrieve the correct file from exception stacktraces.

             To fix this, you'll have to rename one of the conflicting paths.
             """
    end
  end

  test "exception makes call to Sentry API" do
    bypass = Bypass.open()

    modify_env(:sentry,
      enable_source_code_context: true,
      dsn: "http://public:secret@localhost:#{bypass.port}/1"
    )

    mix_shell = Mix.shell()
    on_exit(fn -> Mix.shell(mix_shell) end)

    Mix.shell(Mix.Shell.Quiet)
    Mix.Task.rerun("sentry.package_source_code", ["--debug"])

    :ok = Sentry.Sources.load_source_code_map_if_present()

    correct_context = %{
      "context_line" => "    raise RuntimeError, \"Error\"",
      "post_context" => ["  end", "", "  get \"/exit_route\" do"],
      "pre_context" => ["", "  get \"/error_route\" do", "    _ = conn"]
    }

    Bypass.expect(bypass, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      event = TestHelpers.decode_event_from_envelope!(body)

      frames = Enum.reverse(List.first(event.exception)["stacktrace"]["frames"])

      assert ^correct_context =
               Enum.at(frames, 0)
               |> Map.take(["context_line", "post_context", "pre_context"])

      assert body =~ "RuntimeError"
      assert body =~ "Example"
      assert conn.request_path == "/api/1/envelope/"
      assert conn.method == "POST"
      Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
    end)

    assert_raise(Plug.Conn.WrapperError, "** (RuntimeError) Error", fn ->
      conn(:get, "/error_route")
      |> Sentry.ExamplePlugApplication.call([])
    end)
  end
end
