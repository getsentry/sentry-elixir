defmodule Sentry.Dev.BumperTest do
  # async: false — the bumper snapshots base lockfiles to a fixed path in the system tmp
  # dir keyed by project name ("root"), so concurrent runs would clobber each other.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Sentry.Dev.Bumper
  alias Sentry.Dev.Lockfile

  describe "project_status/3" do
    test "classifies the per-project outcome" do
      assert Bumper.project_status([], [], []) == "unchanged"
      assert Bumper.project_status([%{dep: "a"}], [], []) == "green"
      # A project with only a held-back major and no applied bump didn't change.
      assert Bumper.project_status([], [%{dep: "a"}], []) == "unchanged"
      assert Bumper.project_status([%{dep: "a"}], [%{dep: "b"}], []) == "partial"
      assert Bumper.project_status([%{dep: "a"}], [], [%{dep: "b"}]) == "partial"
    end
  end

  describe "overall_status/2" do
    test "a failed final validation dominates everything" do
      data = %{full_validation_passed: false, optimistic_passed: false}
      assert Bumper.overall_status(data, [%{failed: [], skipped_major: []}]) == "failed"
    end

    test "a clean optimistic pass with nothing skipped is green" do
      data = %{full_validation_passed: true, optimistic_passed: true}
      assert Bumper.overall_status(data, [%{failed: [], skipped_major: []}]) == "green"
    end

    test "any failed or skipped project makes the run partial" do
      data = %{full_validation_passed: true, optimistic_passed: false}

      assert Bumper.overall_status(data, [%{failed: [:x], skipped_major: []}]) == "partial"
      assert Bumper.overall_status(data, [%{failed: [], skipped_major: [:y]}]) == "partial"
    end

    test "a green gradual run (everything kept, nothing skipped) is green" do
      data = %{full_validation_passed: true, optimistic_passed: false}
      assert Bumper.overall_status(data, [%{failed: [], skipped_major: []}]) == "green"
    end
  end

  describe "run/1 orchestration (with an injected runner)" do
    setup do
      base_dir =
        Path.join(System.tmp_dir!(), "bumper_test_#{System.unique_integer([:positive])}")

      File.mkdir_p!(base_dir)
      on_exit(fn -> File.rm_rf!(base_dir) end)

      %{base_dir: base_dir, lock: Path.join(base_dir, "mix.lock")}
    end

    test "optimistic pass: every allowed bump applied at once, run is green", %{
      base_dir: base_dir,
      lock: lock
    } do
      write_lock(lock, %{"good" => "1.0.0", "other" => "1.0.0"})
      targets = %{"good" => "1.1.0", "other" => "1.2.0"}

      {result, _io} =
        with_io(fn ->
          Bumper.run(
            runner: always_green_runner(targets),
            base_dir: base_dir,
            skip_integrations: true
          )
        end)

      assert result.optimistic_passed == true
      assert result.full_validation_passed == true
      assert result.overall_status == "green"

      assert [root] = result.projects
      assert root.status == "green"
      assert root.skipped_major == []
      assert root.failed == []

      assert Enum.sort_by(root.bumped, & &1.dep) == [
               %{dep: "good", from: "1.0.0", to: "1.1.0", also_changed: []},
               %{dep: "other", from: "1.0.0", to: "1.2.0", also_changed: []}
             ]

      # The verified lockfile on disk carries both bumps.
      assert read_versions(lock) == %{"good" => "1.1.0", "other" => "1.2.0"}
    end

    test "bisect: keeps the good bump, attributes the test failure, holds back the major",
         %{base_dir: base_dir, lock: lock} do
      write_lock(lock, %{"good" => "1.0.0", "bad" => "1.0.0", "major" => "1.0.0"})
      # `bad` is an allowed minor bump that nonetheless breaks the suite; `major` crosses a
      # major boundary and is held back without ever being attempted.
      targets = %{"good" => "1.1.0", "bad" => "1.1.0", "major" => "2.0.0"}

      {result, _io} =
        with_io(fn ->
          Bumper.run(
            runner: breaks_when_bad_bumped_runner(targets),
            base_dir: base_dir,
            skip_integrations: true
          )
        end)

      assert result.optimistic_passed == false
      assert result.full_validation_passed == true
      assert result.overall_status == "partial"

      assert [root] = result.projects
      assert root.status == "partial"

      assert [%{dep: "good", from: "1.0.0", to: "1.1.0"}] = root.bumped
      assert [%{dep: "major", from: "1.0.0", to: "2.0.0", reason: "major"}] = root.skipped_major

      assert [%{dep: "bad", from: "1.0.0", to: "1.1.0", failure_type: "tests"} = failure] =
               root.failed

      assert failure.attributed_to == "root"
      assert failure.kept_at == "1.0.0"

      # The good bump is kept; the breaking bump is reverted to its original version.
      assert read_versions(lock) == %{"good" => "1.1.0", "bad" => "1.0.0", "major" => "1.0.0"}
    end
  end

  # A runner where every test passes; `deps.update` writes the target versions.
  defp always_green_runner(targets) do
    fn dir, args, _cmd_opts ->
      lock = Path.join(dir, "mix.lock")

      case args do
        ["deps.update", "--all"] -> write_lock(lock, targets) && {:ok, ""}
        ["deps.update" | deps] -> bump(lock, deps, targets) && {:ok, ""}
        _ -> {:ok, ""}
      end
    end
  end

  # A runner whose suite fails whenever `bad` has been bumped to its target.
  defp breaks_when_bad_bumped_runner(targets) do
    fn dir, args, _cmd_opts ->
      lock = Path.join(dir, "mix.lock")

      case args do
        ["deps.update", "--all"] ->
          write_lock(lock, targets)
          {:ok, ""}

        ["deps.update" | deps] ->
          bump(lock, deps, targets)
          {:ok, ""}

        ["test" | _] ->
          if read_versions(lock)["bad"] == "1.1.0",
            do: {:error, 1, "tests failed because of bad"},
            else: {:ok, ""}

        _ ->
          {:ok, ""}
      end
    end
  end

  defp bump(lock, deps, targets) do
    updated =
      Enum.reduce(deps, read_versions(lock), fn dep, acc ->
        Map.put(acc, dep, Map.fetch!(targets, dep))
      end)

    write_lock(lock, updated)
  end

  defp write_lock(path, versions) do
    body =
      versions
      |> Enum.sort()
      |> Enum.map_join("", fn {name, version} ->
        ~s(  "#{name}": {:hex, :#{name}, "#{version}", "hash", [:mix], [], "hexpm", "outer"},\n)
      end)

    File.write!(path, "%{\n" <> body <> "}\n")
  end

  defp read_versions(path) do
    path
    |> Lockfile.read()
    |> Map.new(fn {name, entry} ->
      {:ok, version} = Lockfile.hex_version(entry)
      {name, version}
    end)
  end
end
