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

    test "accepts string patterns for source_code_exclude_patterns (OTP 28+ compatibility)" do
      paths = [
        File.cwd!() <> "/test/fixtures/example-umbrella-app/apps/app_a",
        File.cwd!() <> "/test/fixtures/example-umbrella-app/apps/app_b"
      ]

      assert {:ok, result} =
               Sources.load_files(
                 root_source_code_paths: paths,
                 source_code_exclude_patterns: ["module_b"]
               )

      assert Map.has_key?(result, "lib/module_a.ex")
      refute Map.has_key?(result, "lib/module_b.ex")
    end

    test "accepts mixed string and regex patterns for source_code_exclude_patterns" do
      paths = [
        File.cwd!() <> "/test/fixtures/example-umbrella-app/apps/app_a",
        File.cwd!() <> "/test/fixtures/example-umbrella-app/apps/app_b"
      ]

      assert {:ok, result} =
               Sources.load_files(
                 root_source_code_paths: paths,
                 source_code_exclude_patterns: [~r/module_a/, "module_b"]
               )

      refute Map.has_key?(result, "lib/module_a.ex")
      refute Map.has_key?(result, "lib/module_b.ex")
    end

    test "string patterns survive term serialization (OTP 28+ release simulation)" do
      paths = [
        File.cwd!() <> "/test/fixtures/example-umbrella-app/apps/app_a",
        File.cwd!() <> "/test/fixtures/example-umbrella-app/apps/app_b"
      ]

      original_config = [
        root_source_code_paths: paths,
        source_code_exclude_patterns: ["module_b", "/deps/"]
      ]

      serialized = :erlang.term_to_binary(original_config)
      deserialized_config = :erlang.binary_to_term(serialized)

      assert {:ok, result} = Sources.load_files(deserialized_config)
      assert Map.has_key?(result, "lib/module_a.ex")
      refute Map.has_key?(result, "lib/module_b.ex")
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
    test "reads the source code map from the file", %{tmp_dir: tmp_dir} do
      encoded_map = Sources.encode_source_code_map(%{"foo.ex" => %{}})
      path = Path.join(tmp_dir, "valid.map")
      File.write!(path, encoded_map)
      assert {:loaded, map} = Sources.load_source_code_map_if_present(path)
      assert map == %{"foo.ex" => %{}}
    end
  end

  describe "get_source_context/2" do
    test "returns the correct context" do
      map = %{
        1 => "defmodule Foo do",
        2 => "  def bar do",
        3 => "    \"bar\"",
        4 => "  end",
        5 => "end"
      }

      assert {pre, context, post} = Sources.get_source_context(map, 4)
      assert pre == ["defmodule Foo do", "  def bar do", "    \"bar\""]
      assert context == "  end"
      assert post == ["end"]
    end

    test "works if the line number doesn't exist" do
      assert {[], nil, []} = Sources.get_source_context(%{}, 4)
    end
  end
end
