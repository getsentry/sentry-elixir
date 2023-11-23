defmodule Sentry.SourcesTest do
  use Sentry.Case, async: true

  describe "load_files/1" do
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
              }} =
               Sentry.Sources.load_files(
                 root_source_code_paths: paths,
                 source_code_exclude_patterns: []
               )
    end

    test "raises error when two files have the same relative path" do
      paths = [
        File.cwd!() <> "/test/fixtures/example-umbrella-app-with-conflict/apps/app_a",
        File.cwd!() <> "/test/fixtures/example-umbrella-app-with-conflict/apps/app_b"
      ]

      assert {:error, message} =
               Sentry.Sources.load_files(
                 root_source_code_paths: paths,
                 source_code_exclude_patterns: []
               )

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
end
