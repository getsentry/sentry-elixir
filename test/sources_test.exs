defmodule Sentry.SourcesTest do
  use ExUnit.Case
  use Plug.Test
  import Sentry.TestEnvironmentHelper

  describe "load_files/0" do
    test "loads files" do
      modify_env(:sentry, root_source_code_paths: [
        File.cwd!() <> "/test/support/example-umbrella-app/apps/app_a",
        File.cwd!() <> "/test/support/example-umbrella-app/apps/app_b"
      ])

      assert %{
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
             } = Sentry.Sources.load_files()
    end

    test "raises error when two files have the same relative path" do
      modify_env(:sentry, root_source_code_paths: [
        File.cwd!() <> "/test/support/example-umbrella-app-with-conflict/apps/app_a",
        File.cwd!() <> "/test/support/example-umbrella-app-with-conflict/apps/app_b"
      ])

      expected_error_message = """
      Found two source files in different source root paths with the same relative \
      path: lib/module_a.ex

      This means that both source files would be reported to Sentry as the same \
      file. Please rename one of them to avoid this.
      """

      assert_raise RuntimeError, expected_error_message, fn ->
        Sentry.Sources.load_files()
      end
    end
  end

  test "exception makes call to Sentry API" do
    correct_context = %{
      "context_line" => "    raise RuntimeError, \"Error\"",
      "post_context" => ["  end", "", "  post \"/error_route\" do"],
      "pre_context" => ["", "  get \"/error_route\" do", "    _ = conn"]
    }

    bypass = Bypass.open()

    Bypass.expect(bypass, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      frames =
        Jason.decode!(body)
        |> get_in(["stacktrace", "frames"])
        |> Enum.reverse()

      assert ^correct_context =
               Enum.at(frames, 0)
               |> Map.take(["context_line", "post_context", "pre_context"])

      assert body =~ "RuntimeError"
      assert body =~ "Example"
      assert conn.request_path == "/api/1/store/"
      assert conn.method == "POST"
      Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
    end)

    modify_env(:sentry, dsn: "http://public:secret@localhost:#{bypass.port}/1")

    assert_raise(Plug.Conn.WrapperError, "** (RuntimeError) Error", fn ->
      conn(:get, "/error_route")
      |> Sentry.ExamplePlugApplication.call([])
    end)
  end
end
