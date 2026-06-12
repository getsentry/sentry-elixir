defmodule Sentry.Dev.Bumper do
  @moduledoc """
  Orchestrates the careful lockfile bump for `mix sentry.bump_lockfiles`.

  The strategy is optimistic-first: bump every policy-allowed dependency at once and
  run the full test suite. If that is green we are done. Otherwise we revert and bump
  one dependency at a time (cumulative greedy), running the full suite after each, so
  the assembled lockfiles are always a validated, passing set and we can attribute the
  breakage to a specific dependency.

  This module is dev/CI tooling and is not part of the public API.
  """

  @moduledoc since: "13.3.0"

  alias Sentry.Dev.Cmd
  alias Sentry.Dev.Lockfile
  alias Sentry.Dev.VersionPolicy

  @integrations [
    %{name: "prod_mode", subdir: "prod_mode", mix_env: "prod"},
    %{name: "umbrella", subdir: "umbrella", mix_env: "test"},
    %{name: "phoenix_app", subdir: "phoenix_app", mix_env: "test"},
    %{name: "legacy_otel", subdir: "legacy_otel", mix_env: "test"}
  ]

  @log_snippet_bytes 6_000

  @doc """
  Runs the full bump and returns the data needed to build the JSON report.
  """
  @spec run(keyword()) :: map()
  def run(opts) do
    vp_opts =
      VersionPolicy.opts(
        allow_major: opts[:allow_major] || false,
        allow_major_for: csv(opts[:allow_major_for]),
        strict_0x: Keyword.get(opts, :strict_0x, true)
      )

    only = csv(opts[:only])
    projects = discover_projects(opts)
    snapshot_base(projects)

    try do
      discovered = Enum.map(projects, &discover_candidates(&1, vp_opts, only, opts))
      run_phases(projects, discovered, vp_opts, opts)
    after
      Enum.each(projects, &File.rm(&1.base_backup))
    end
  end

  ## Project discovery

  defp discover_projects(opts) do
    only_projects = csv(opts[:projects])
    root = %{name: "root", dir: ".", mix_env: "test", kind: :root, check_locked: false}

    integrations =
      for int <- @integrations do
        %{
          name: int.name,
          dir: Path.join("test_integrations", int.subdir),
          mix_env: int.mix_env,
          kind: :integration,
          check_locked: true
        }
      end

    all = if opts[:skip_integrations], do: [root], else: [root | integrations]
    all = if only_projects == [], do: all, else: Enum.filter(all, &(&1.name in only_projects))

    Enum.map(all, fn project ->
      backup = Path.join(System.tmp_dir!(), "sentry_bump_base_#{project.name}.lock")
      Map.put(project, :base_backup, backup)
    end)
  end

  defp lock_path(project), do: Path.join(project.dir, "mix.lock")

  ## Base snapshot / restore

  defp snapshot_base(projects) do
    Enum.each(projects, fn project ->
      lock = lock_path(project)
      if File.exists?(lock), do: File.cp!(lock, project.base_backup)
    end)
  end

  defp restore_base(project) do
    if File.exists?(project.base_backup) do
      File.cp!(project.base_backup, lock_path(project))
    end
  end

  defp base_lock(project), do: Lockfile.read(project.base_backup)

  ## Candidate discovery

  # Bumps everything once to learn what *can* move, then restores the lock. Splits the
  # available bumps into ones we're allowed to apply and ones skipped as a major bump.
  defp discover_candidates(project, vp_opts, only, opts) do
    base = base_lock(project)
    log_to = log_path(opts, "discover-#{project.name}")

    case Cmd.mix(project.dir, ["deps.update", "--all"], env: env(project), log_to: log_to) do
      {:ok, _output} ->
        new = Lockfile.read(lock_path(project))
        restore_base(project)

        candidates =
          base
          |> Lockfile.diff(new)
          # Newly-added transitive deps (from: nil) can't be updated on their own — they
          # only appear when their parent is bumped, so they ride along as also_changed.
          |> Enum.reject(&is_nil(&1.from))
          |> filter_only(only)

        {allowed, skipped} =
          Enum.split_with(candidates, &VersionPolicy.allowed?(&1.dep, &1.from, &1.to, vp_opts))

        skipped_major =
          Enum.map(skipped, &Map.put(&1, :reason, skip_reason(&1, vp_opts)))

        %{project: project, allowed: allowed, skipped_major: skipped_major}

      {:error, status, output} ->
        restore_base(project)

        Mix.raise(
          "`mix deps.update --all` failed in #{project.dir} (exit #{status}):\n" <> tail(output)
        )
    end
  end

  defp skip_reason(change, vp_opts),
    do: to_string(VersionPolicy.classify(change.from, change.to, vp_opts))

  defp filter_only(candidates, []), do: candidates
  defp filter_only(candidates, only), do: Enum.filter(candidates, &(&1.dep in only))

  ## Phase orchestration

  defp run_phases(projects, discovered, vp_opts, opts) do
    skipped_by_project = Map.new(discovered, &{&1.project.name, &1.skipped_major})

    case optimistic(discovered, vp_opts, opts) do
      {:ok, bumped_by_project} ->
        build_result(projects, opts, %{
          optimistic_passed: true,
          full_validation_passed: true,
          bumped: bumped_by_project,
          skipped: skipped_by_project,
          failed: %{}
        })

      {:failed, reason} ->
        Mix.shell().info([
          :yellow,
          "Optimistic bump did not pass (#{reason}); bisecting.",
          :reset
        ])

        Enum.each(projects, &restore_base/1)
        gradual(projects, discovered, skipped_by_project, vp_opts, opts)
    end
  end

  ## Optimistic phase — apply every allowed bump at once, then validate

  defp optimistic(discovered, vp_opts, opts) do
    results = Enum.map(discovered, &apply_allowed(&1, vp_opts, opts))

    cond do
      Enum.any?(results, &(&1 == :error)) ->
        {:failed, "could not apply allowed bumps"}

      Enum.any?(results, &(&1 == :dragged)) ->
        {:failed, "applying allowed bumps would cross a major boundary"}

      true ->
        case validate_all(projects_of(discovered), opts, "optimistic") do
          :ok -> {:ok, optimistic_bumps(discovered)}
          {:fail, name, failure_type, _log} -> {:failed, "#{name}: #{failure_type}"}
        end
    end
  end

  defp apply_allowed(%{project: project, allowed: allowed}, vp_opts, opts) do
    case Enum.map(allowed, & &1.dep) do
      [] ->
        :ok

      names ->
        log_to = log_path(opts, "optimistic")

        case Cmd.mix(project.dir, ["deps.update" | names], env: env(project), log_to: log_to) do
          {:ok, _} -> if dragged_forbidden?(project, vp_opts), do: :dragged, else: :ok
          {:error, _status, _output} -> :error
        end
    end
  end

  defp dragged_forbidden?(project, vp_opts) do
    project
    |> base_lock()
    |> Lockfile.diff(Lockfile.read(lock_path(project)))
    |> Enum.any?(&(not VersionPolicy.allowed?(&1.dep, &1.from, &1.to, vp_opts)))
  end

  defp optimistic_bumps(discovered) do
    Map.new(discovered, fn %{project: project} ->
      bumped =
        project
        |> base_lock()
        |> Lockfile.diff(Lockfile.read(lock_path(project)))
        |> Enum.map(&Map.merge(&1, %{also_changed: []}))

      {project.name, bumped}
    end)
  end

  ## Gradual phase (cumulative greedy)

  defp gradual(projects, discovered, skipped_by_project, vp_opts, opts) do
    worklist =
      Enum.flat_map(discovered, fn %{project: project, allowed: allowed} ->
        Enum.map(allowed, &Map.put(&1, :project, project))
      end)

    initial_acc = %{
      bumped: Map.new(projects, &{&1.name, []}),
      skipped: skipped_by_project,
      failed: Map.new(projects, &{&1.name, []})
    }

    acc =
      Enum.reduce(worklist, initial_acc, fn item, acc ->
        attempt_bump(item, projects_of(discovered), vp_opts, opts, acc)
      end)

    full_ok = opts[:no_final_check] || validate_all(projects_of(discovered), opts, "final") == :ok

    build_result(projects, opts, %{
      optimistic_passed: false,
      full_validation_passed: full_ok,
      bumped: acc.bumped,
      skipped: acc.skipped,
      failed: acc.failed
    })
  end

  defp attempt_bump(item, all_projects, vp_opts, opts, acc) do
    project = item.project
    lock = lock_path(project)
    pre = Lockfile.read(lock)

    if already_at_target?(pre, item) do
      # A previous kept bump already dragged this dep to its target as a sibling, so
      # it's recorded there — re-attempting would double-list it.
      acc
    else
      try_bump(item, project, lock, pre, all_projects, vp_opts, opts, acc)
    end
  end

  defp already_at_target?(lock, item) do
    Lockfile.hex_version(Map.get(lock, item.dep)) == {:ok, item.to}
  end

  defp try_bump(item, project, lock, pre, all_projects, vp_opts, opts, acc) do
    bak = lock <> ".sentry_bump_bak"
    File.cp!(lock, bak)
    label = gradual_label(item.dep)

    Mix.shell().info([
      :cyan,
      "==> Trying #{project.name}: #{item.dep} #{item.from} -> #{item.to}",
      :reset
    ])

    result =
      case Cmd.mix(project.dir, ["deps.update", item.dep],
             env: env(project),
             log_to: log_path(opts, label)
           ) do
        {:ok, _output} ->
          evaluate_step(item, project, pre, all_projects, vp_opts, opts, label)

        {:error, status, output} ->
          {:reject, :deps_get, project.name, "exit #{status}\n#{tail(output)}"}
      end

    record_step(result, item, project, bak, opts, acc)
  end

  defp evaluate_step(item, project, pre, all_projects, vp_opts, opts, label) do
    step_changes = Lockfile.diff(pre, Lockfile.read(lock_path(project)))

    if Enum.any?(step_changes, &(not VersionPolicy.allowed?(&1.dep, &1.from, &1.to, vp_opts))) do
      {:skip_major, "requires_major_dep"}
    else
      also_changed = Enum.reject(step_changes, &(&1.dep == item.dep))

      case validate_all(all_projects, opts, label) do
        :ok -> {:keep, also_changed}
        {:fail, name, failure_type, log} -> {:reject, failure_type, name, log}
      end
    end
  end

  defp record_step({:keep, also_changed}, item, project, bak, _opts, acc) do
    File.rm(bak)
    Mix.shell().info([:green, "    kept #{item.dep}", :reset])
    bumped = item |> Map.merge(%{also_changed: also_changed}) |> Map.delete(:project)
    append(acc, :bumped, project.name, bumped)
  end

  defp record_step({:skip_major, reason}, item, project, bak, _opts, acc) do
    restore_step(project, bak)
    Mix.shell().info([:yellow, "    skipped #{item.dep} (#{reason})", :reset])
    skipped = item |> Map.put(:reason, reason) |> Map.delete(:project)
    append(acc, :skipped, project.name, skipped)
  end

  defp record_step({:reject, failure_type, manifest_project, log}, item, project, bak, opts, acc) do
    restore_step(project, bak)

    Mix.shell().info([
      :red,
      "    failed #{item.dep} (#{failure_type} in #{manifest_project})",
      :reset
    ])

    failed =
      item
      |> Map.merge(%{
        failure_type: to_string(failure_type),
        attributed_to: project.name,
        manifested_in: manifest_project,
        kept_at: item.from,
        log_file: relative_log_file(opts, gradual_label(item.dep)),
        log_snippet: tail(log)
      })
      |> Map.delete(:project)

    append(acc, :failed, project.name, failed)
  end

  defp restore_step(project, bak) do
    File.cp!(bak, lock_path(project))
    File.rm(bak)
    Cmd.mix(project.dir, ["deps.get"], env: env(project))
  end

  defp append(acc, key, project_name, value),
    do: update_in(acc, [key, project_name], &(&1 ++ [value]))

  ## Validation oracle

  defp validate_all(projects, opts, label) do
    log_to = log_path(opts, label)

    Enum.reduce_while(projects, :ok, fn project, :ok ->
      case validate_project(project, opts, log_to) do
        :ok -> {:cont, :ok}
        {:fail, failure_type, log} -> {:halt, {:fail, project.name, failure_type, log}}
      end
    end)
  end

  defp validate_project(project, opts, log_to) do
    cmd_opts = [
      env: env(project),
      verbose: opts[:verbose],
      timeout: opts[:timeout],
      log_to: log_to
    ]

    deps_get_args =
      if project.check_locked, do: ["deps.get", "--check-locked"], else: ["deps.get"]

    with {:deps, {:ok, _}} <- {:deps, Cmd.mix(project.dir, deps_get_args, cmd_opts)},
         {:compile, {:ok, _}} <- {:compile, Cmd.mix(project.dir, ["compile"], cmd_opts)},
         {:test, {:ok, _}} <- {:test, Cmd.mix(project.dir, ["test", "--no-color"], cmd_opts)} do
      :ok
    else
      {:deps, {:error, _status, log}} ->
        {:fail, if(project.check_locked, do: :deps_locked, else: :deps_get), log}

      {:compile, {:error, _status, log}} ->
        {:fail, :build, log}

      {:test, {:error, _status, log}} ->
        {:fail, :tests, log}
    end
  end

  ## Helpers

  defp projects_of(discovered), do: Enum.map(discovered, & &1.project)

  defp env(project), do: [{"MIX_ENV", project.mix_env}]

  defp gradual_label(dep), do: "gradual-#{dep}"

  # Absolute path of the log file for a labelled step, or nil when logging is disabled.
  defp log_path(opts, label) do
    case opts[:logs_dir] do
      nil -> nil
      dir -> Path.join(dir, "#{label}.log")
    end
  end

  # Path of the log file relative to the run directory, for inclusion in the report.
  defp relative_log_file(opts, label) do
    if opts[:logs_dir], do: Path.join("logs", "#{label}.log")
  end

  defp csv(nil), do: []

  defp csv(str) when is_binary(str),
    do: str |> String.split(",", trim: true) |> Enum.map(&String.trim/1)

  defp tail(output) when is_binary(output) do
    if byte_size(output) > @log_snippet_bytes do
      "...(truncated)...\n" <>
        binary_part(output, byte_size(output) - @log_snippet_bytes, @log_snippet_bytes)
    else
      output
    end
  end

  ## Result assembly

  defp build_result(projects, opts, data) do
    project_results =
      Enum.map(projects, fn project ->
        bumped = Map.get(data.bumped, project.name, [])
        skipped = Map.get(data.skipped, project.name, [])
        failed = Map.get(data.failed, project.name, [])

        %{
          name: project.name,
          dir: project.dir,
          mix_env: project.mix_env,
          optimistic_passed: data.optimistic_passed,
          status: project_status(bumped, skipped, failed),
          bumped: bumped,
          skipped_major: skipped,
          failed: failed
        }
      end)

    %{
      optimistic_passed: data.optimistic_passed,
      full_validation_passed: data.full_validation_passed,
      overall_status: overall_status(data, project_results),
      options: normalize_options(opts),
      projects: project_results
    }
  end

  defp project_status(bumped, skipped, failed) do
    cond do
      failed != [] -> "partial"
      skipped != [] and bumped != [] -> "partial"
      bumped == [] -> "unchanged"
      true -> "green"
    end
  end

  defp overall_status(data, project_results) do
    any_failed = Enum.any?(project_results, &(&1.failed != []))
    any_skipped = Enum.any?(project_results, &(&1.skipped_major != []))

    cond do
      not data.full_validation_passed -> "failed"
      data.optimistic_passed and not any_skipped -> "green"
      any_failed or any_skipped -> "partial"
      true -> "green"
    end
  end

  defp normalize_options(opts) do
    %{
      allow_major: opts[:allow_major] || false,
      allow_major_for: csv(opts[:allow_major_for]),
      strict_0x: Keyword.get(opts, :strict_0x, true),
      only: csv(opts[:only]),
      projects: csv(opts[:projects]),
      skip_integrations: opts[:skip_integrations] || false,
      no_final_check: opts[:no_final_check] || false
    }
  end
end
