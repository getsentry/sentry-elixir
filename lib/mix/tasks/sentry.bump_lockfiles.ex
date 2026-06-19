defmodule Mix.Tasks.Sentry.BumpLockfiles do
  @shortdoc "Carefully bumps dependency lockfiles, keeping only changes that pass tests"

  @moduledoc """
  Carefully bumps the project's `mix.lock` files, keeping only the dependency updates
  that are proven not to break compilation or tests.

  The weekly `update_lockfiles` GitHub workflow refreshes every `mix.lock` with a blunt
  `mix deps.update --all`, which can silently introduce a breaking dependency bump. This
  task does the same refresh, but *gradually and safely*: it never crosses a major
  version by default, validates against the full test suite (including integration
  tests), and emits a JSON report naming exactly which dependencies were bumped, which
  were skipped as major, and which broke the build or the tests.

  ## How it works

  1. **Snapshot** every lockfile so any step can be reverted.
  2. **Optimistic phase** — apply every policy-allowed bump at once and run the full
     suite. If it's green, we're done.
  3. **Gradual phase** (only on failure) — revert, then bump one dependency at a time,
     running the full suite after each. A bump is kept only if everything stays green,
     so the assembled lockfiles are always a validated, passing set, and the dependency
     responsible for any breakage is identified.
  4. **Artifacts** — write a self-contained run directory and print a colored summary.

  ## Run artifacts

  Each run creates a timestamped directory under `--output-dir` (default
  `tmp/lockfile-bump`) so results are easy to inspect and turn into follow-up tasks:

  ```text
  tmp/lockfile-bump/
    latest -> run-<timestamp>        # symlink to the most recent run
    run-<timestamp>/
      report.json                    # full structured report
      locks/                         # the verified mix.lock files (used by --apply)
      logs/
        discover-<project>.log       # output of `deps.update --all` per project
        optimistic.log               # the optimistic bump-everything validation
        gradual-<dep>.log            # full deps.get/compile/test output per attempted bump
        final.log                    # the final full validation
  ```

  Each failed dependency in `report.json` references its `log_file` so you can jump
  straight to the relevant test output.

  ## Lockfiles

  Bumps the root `mix.lock` and the `mix.lock` of each integration project that the
  `test.integrations` suite validates: `prod_mode`, `umbrella`, `phoenix_app`, and
  `legacy_otel`. The `tracing` integration is intentionally excluded — it relies on a
  Playwright end-to-end suite that is not part of this task's validation oracle, so its
  lockfile is left untouched.

  ## Major versions

  By default no bump crosses a major boundary. Following semver, a `0.x` minor bump
  (e.g. `0.20 -> 0.21`) is also treated as breaking. Use `--allow-major` or
  `--allow-major-for` to opt in.

  ## Performance

  Best case (everything passes optimistically) runs the suite once. The gradual phase
  runs the full suite per attempted dependency, which can be slow — scope it down with
  `--only`, `--projects`, or `--skip-integrations` when iterating locally.

  ## Usage

  ```shell
  mix sentry.bump_lockfiles
  mix sentry.bump_lockfiles --skip-integrations --output-dir tmp/bumps
  mix sentry.bump_lockfiles --allow-major-for opentelemetry,opentelemetry_api
  mix sentry.bump_lockfiles --apply tmp/lockfile-bump/latest
  ```

  ## Options

    * `--allow-major` - allow bumps that cross a major boundary
    * `--allow-major-for dep1,dep2` - allow major bumps only for the listed dependencies
    * `--strict-0x` / `--no-strict-0x` - treat `0.x` minor bumps as breaking (default: true)
    * `--only dep1,dep2` - only consider the listed dependencies
    * `--projects root,phoenix_app` - only operate on the listed projects
    * `--skip-integrations` - only bump and validate the root project
    * `--output-dir DIR` - base directory for run artifacts (default: `tmp/lockfile-bump`).
      Each run creates a timestamped subdirectory; see "Run artifacts" above.
    * `--apply PATH` - skip discovery/verification and apply the *exact* verified
      lockfiles captured by a previous run (e.g. one produced by an earlier `--dry-run`).
      `PATH` is a run directory (or its `report.json`); this copies the captured
      lockfiles back verbatim and runs `mix deps.get`. No tests are re-run. Combine with
      `--projects` to apply to a subset.
    * `--dry-run` - run everything but restore the original lockfiles afterward
    * `--timeout SECONDS` - hard cap per test run; the run is killed and recorded as a failure
    * `--verbose` - stream subprocess output live
    * `--no-final-check` - skip the final full validation of the assembled lockfiles
    * `--keep-going` - always exit 0 (report-only); by default a `failed` result exits non-zero

  """

  @moduledoc since: "13.3.0"

  use Mix.Task

  alias Sentry.Dev.Applier
  alias Sentry.Dev.Bumper
  alias Sentry.Dev.Report

  @switches [
    allow_major: :boolean,
    allow_major_for: :string,
    strict_0x: :boolean,
    only: :string,
    projects: :string,
    skip_integrations: :boolean,
    output_dir: :string,
    apply: :string,
    dry_run: :boolean,
    timeout: :integer,
    verbose: :boolean,
    no_final_check: :boolean,
    keep_going: :boolean
  ]

  @default_output_dir "tmp/lockfile-bump"

  @impl true
  def run(args) do
    {opts, _args} = OptionParser.parse!(args, strict: @switches)

    case opts[:apply] do
      nil -> bump(opts)
      path -> apply_report(path, opts)
    end
  end

  defp apply_report(path, opts) do
    summary = path |> report_path() |> Report.read() |> Applier.apply(opts)
    Applier.print_summary(summary)

    if not summary.all_applied? and not opts[:keep_going] do
      Mix.shell().error("Some lockfiles could not be applied. See above.")
      exit({:shutdown, 1})
    end
  end

  # `--apply` accepts either a run directory or a direct path to its report.json.
  defp report_path(path) do
    if File.dir?(path), do: Path.join(path, "report.json"), else: path
  end

  defp bump(opts) do
    run_dir = new_run_dir(opts)
    logs_dir = Path.join(run_dir, "logs")
    locks_dir = Path.join(run_dir, "locks")
    File.mkdir_p!(logs_dir)
    backups = if opts[:dry_run], do: backup_lockfiles(), else: nil

    report =
      try do
        result = opts |> Keyword.put(:logs_dir, logs_dir) |> Bumper.run()
        # Capture the verified lockfiles (on disk now) so they can be applied later,
        # before any dry-run restore reverts the working tree.
        save_verified_locks(locks_dir)

        result
        |> Report.build()
        |> Map.merge(%{
          run_dir: Path.relative_to_cwd(run_dir),
          logs_dir: Path.relative_to_cwd(logs_dir),
          verified_locks_dir: Path.relative_to_cwd(locks_dir)
        })
      after
        if backups, do: restore_lockfiles(backups)
      end

    Report.write(report, Path.join(run_dir, "report.json"))
    Report.print_summary(report)
    _ = update_latest(run_dir)

    Mix.shell().info([
      "\nRun artifacts written to ",
      :cyan,
      Path.relative_to_cwd(run_dir),
      :reset
    ])

    Mix.shell().info([
      "Apply the verified lockfiles later with: ",
      :bright,
      "mix sentry.bump_lockfiles --apply #{Path.relative_to_cwd(run_dir)}",
      :reset
    ])

    if report.overall_status == "failed" and not opts[:keep_going] do
      Mix.shell().error(
        "Could not assemble a green set of lockfiles. See the report for details."
      )

      exit({:shutdown, 1})
    end
  end

  defp new_run_dir(opts) do
    base = Keyword.get(opts, :output_dir, @default_output_dir)
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601() |> String.replace(":", "-")
    Path.join(base, "run-#{timestamp}")
  end

  # Best-effort `latest` symlink pointing at the most recent run, so `--apply <base>/latest`
  # works without knowing the timestamp. Tolerates filesystems that disallow symlinks.
  defp update_latest(run_dir) do
    latest = Path.join(Path.dirname(run_dir), "latest")
    _ = File.rm(latest)
    File.ln_s(Path.basename(run_dir), latest)
  rescue
    _ -> :ok
  end

  defp lockfiles do
    Path.wildcard("mix.lock") ++ Path.wildcard("test_integrations/*/mix.lock")
  end

  defp save_verified_locks(locks_dir) do
    Enum.each(lockfiles(), fn lock ->
      dest = Path.join(locks_dir, lock)
      File.mkdir_p!(Path.dirname(dest))
      File.cp!(lock, dest)
    end)
  end

  defp backup_lockfiles do
    Map.new(lockfiles(), fn lock ->
      backup = Path.join(System.tmp_dir!(), "sentry_bump_dryrun_#{:erlang.phash2(lock)}.lock")
      File.cp!(lock, backup)
      {lock, backup}
    end)
  end

  defp restore_lockfiles(backups) do
    Enum.each(backups, fn {lock, backup} ->
      File.cp!(backup, lock)
      _ = File.rm(backup)

      # Reconcile the on-disk deps with the restored lock, otherwise the next compile
      # fails with a lock mismatch because the run fetched newer versions. This runs in
      # the dry-run cleanup path; a failure here can't abort the already-finished run,
      # but it must not pass silently — warn loudly with the real reason.
      case Sentry.Dev.Cmd.mix(Path.dirname(lock), ["deps.get"]) do
        {:ok, _output} ->
          :ok

        {:error, status, output} ->
          Mix.shell().error(
            "Warning: could not reconcile #{lock} after the dry-run restore (exit #{status}). " <>
              "You may need to run `mix deps.get` manually.\n#{output}"
          )
      end
    end)
  end
end
