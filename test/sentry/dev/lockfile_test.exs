defmodule Sentry.Dev.LockfileTest do
  use ExUnit.Case, async: true

  alias Sentry.Dev.Lockfile

  @hex_entry {:hex, :plug, "1.16.0", "hash", [:mix], [], "hexpm", "outer"}
  @git_entry {:git, "https://github.com/example/heroicons.git", "abc123", [tag: "v2.1.1"]}

  defp write_lock(contents) do
    path =
      Path.join(System.tmp_dir!(), "lockfile_test_#{System.unique_integer([:positive])}.lock")

    File.write!(path, contents)
    on_exit(fn -> File.rm(path) end)
    path
  end

  describe "read/1" do
    test "parses a lockfile into a map" do
      path =
        write_lock(~s|%{
          "plug": {:hex, :plug, "1.16.0", "hash", [:mix], [], "hexpm", "outer"},
        }|)

      lock = Lockfile.read(path)
      assert {:ok, "1.16.0"} = Lockfile.hex_version(lock["plug"])
    end

    test "parses git entries with keyword-list options" do
      path =
        write_lock(~s|%{
          "heroicons": {:git, "https://github.com/example/heroicons.git", "abc123", [tag: "v2.1.1"]},
        }|)

      lock = Lockfile.read(path)
      assert Lockfile.hex_version(lock["heroicons"]) == :not_hex
    end

    test "returns an empty map for a missing file" do
      assert Lockfile.read(Path.join(System.tmp_dir!(), "does_not_exist.lock")) == %{}
    end

    test "rejects a non-literal lockfile instead of executing it" do
      # If read/1 evaluated the file, this send/2 would deliver a message to the test
      # process. It must raise on the non-literal expression and run nothing.
      path = write_lock(~s|%{"x" => send(self(), :pwned)}|)

      assert_raise ArgumentError, ~r/non-literal/, fn -> Lockfile.read(path) end
      refute_received :pwned
    end
  end

  describe "hex_version/1" do
    test "extracts the version from hex entries" do
      assert Lockfile.hex_version(@hex_entry) == {:ok, "1.16.0"}
    end

    test "returns :not_hex for git entries" do
      assert Lockfile.hex_version(@git_entry) == :not_hex
    end
  end

  describe "diff/2" do
    test "reports only changed hex versions, sorted by dep, skipping git entries" do
      old = %{
        "plug" => {:hex, :plug, "1.16.0", "h", [:mix], [], "hexpm", "o"},
        "jason" => {:hex, :jason, "1.4.0", "h", [:mix], [], "hexpm", "o"},
        "heroicons" => @git_entry
      }

      new = %{
        "plug" => {:hex, :plug, "1.17.0", "h", [:mix], [], "hexpm", "o"},
        "jason" => {:hex, :jason, "1.4.0", "h", [:mix], [], "hexpm", "o"},
        "heroicons" =>
          {:git, "https://github.com/example/heroicons.git", "def456", [tag: "v2.2.0"]}
      }

      assert Lockfile.diff(old, new) == [%{dep: "plug", from: "1.16.0", to: "1.17.0"}]
    end

    test "reports newly added deps with from: nil" do
      old = %{}
      new = %{"plug" => {:hex, :plug, "1.17.0", "h", [:mix], [], "hexpm", "o"}}

      assert Lockfile.diff(old, new) == [%{dep: "plug", from: nil, to: "1.17.0"}]
    end
  end
end
