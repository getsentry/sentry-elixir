defmodule Mix.Tasks.Sentry.BumpLockfilesTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Sentry.BumpLockfiles

  describe "relocate_locks_dir/2" do
    test "re-anchors the verified locks dir to the report's own directory" do
      # The stored path is relative to the bump-time cwd, but the locks always live next
      # to the report. Re-anchoring makes --apply work from any cwd / a moved run dir.
      report = %{"verified_locks_dir" => "tmp/lockfile-bump/run-2026-06-19/locks"}

      relocated =
        BumpLockfiles.relocate_locks_dir(report, "/downloads/run-2026-06-19/report.json")

      assert relocated["verified_locks_dir"] == "/downloads/run-2026-06-19/locks"
    end

    test "works when --apply points at the run directory (report.json appended)" do
      report = %{"verified_locks_dir" => "tmp/lockfile-bump/run-x/locks"}

      relocated =
        BumpLockfiles.relocate_locks_dir(report, "relative/run-x/report.json")

      assert relocated["verified_locks_dir"] == "relative/run-x/locks"
    end

    test "leaves a report without captured lockfiles untouched" do
      report = %{"projects" => []}

      assert BumpLockfiles.relocate_locks_dir(report, "/anywhere/report.json") == report
    end
  end
end
