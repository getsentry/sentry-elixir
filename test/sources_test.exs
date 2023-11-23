defmodule Sentry.SourcesTest do
  # Not async because we're capturing IO.
  use Sentry.Case, async: false

  import ExUnit.CaptureIO

  alias Sentry.Sources

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
               Sources.load_files(
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
               Sources.load_files(
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

  describe "load_source_code_map_if_present/0" do
    @tag :tmp_dir
    test "fails if the source code map at the destination is malformed", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "malformed.map")
      File.write!(path, "hello!")

      output =
        capture_io(:stderr, fn ->
          assert {:error, :decoding_error} = Sources.load_source_code_map_if_present(path)
        end)

      assert output =~ "Sentry found a source code map file"
      assert output =~ "but it was unable to decode"
    end

    @tag :tmp_dir
    test "stores the source code map in :persistent_term if valid", %{tmp_dir: tmp_dir} do
      encoded_map = Sources.encode_source_code_map(%{"foo.ex" => %{}})
      path = Path.join(tmp_dir, "valid.map")
      File.write!(path, encoded_map)
      assert {:loaded, map} = Sources.load_source_code_map_if_present(path)
      assert map == %{"foo.ex" => %{}}
      assert :persistent_term.get({:sentry, :source_code_map}) == %{"foo.ex" => %{}}
    after
      :persistent_term.erase({:sentry, :source_code_map})
    end
  end

  describe "get_source_context/3" do
    test "returns the correct context" do
      map = %{
        "foo.ex" => %{
          1 => "defmodule Foo do",
          2 => "  def bar do",
          3 => "    \"bar\"",
          4 => "  end",
          5 => "end"
        },
        "bar.ex" => %{
          1 => "defmodule Bar do",
          2 => "  def baz do",
          3 => "    \"baz\"",
          4 => "  end",
          5 => "end"
        }
      }

      assert {pre, context, post} = Sources.get_source_context(map, "foo.ex", 4)
      assert pre == ["defmodule Foo do", "  def bar do", "    \"bar\""]
      assert context == "  end"
      assert post == ["end"]
    end

    test "works if the file doesn't exist" do
      assert {[], nil, []} = Sources.get_source_context(%{}, "foo.ex", 4)
    end
  end
end
