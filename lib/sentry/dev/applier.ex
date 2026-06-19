defmodule Sentry.Dev.Applier do
  @moduledoc """
  Applies the verified lockfiles captured by a prior `mix sentry.bump_lockfiles` run.

  A bump run (including a `--dry-run`) saves the exact verified `mix.lock` files to a
  sidecar directory next to the report. This module copies those lockfiles back into the
  working tree verbatim and runs `mix deps.get` to materialize them — no tests are
  re-run and nothing is re-resolved, so the applied versions are precisely the ones that
  were verified.

  Re-resolving from the report's version list is deliberately *not* used: updating a
  subset of dependencies (`mix deps.update <deps>`) can pick different versions than the
  full run did, so only the captured lockfiles reproduce the verified set exactly.

  This module is dev/CI tooling and is not part of the public API.
  """

  @moduledoc since: "13.3.0"

  alias Sentry.Dev
  alias Sentry.Dev.Cmd

  @doc """
  Applies the verified lockfiles referenced by `report` to the working tree.

  Honors `:projects` (a CSV string of project names to restrict to). Returns a summary
  map with one entry per applied project.
  """
  @spec apply(map(), keyword()) :: map()
  def apply(report, opts) do
    locks_dir = report["verified_locks_dir"] || raise_no_locks()
    only = Dev.csv(opts[:projects])

    results =
      report["projects"]
      |> filter_projects(only)
      |> Enum.map(&apply_project(&1, locks_dir))

    %{
      source_report: report["generated_at"],
      projects: results,
      all_applied?: Enum.all?(results, &(&1.status == "applied"))
    }
  end

  defp apply_project(project, locks_dir) do
    name = project["name"]
    dir = project["dir"]
    src = Path.join(locks_dir, Path.join(dir, "mix.lock"))
    bumped = length(project["bumped"])

    if File.exists?(src) do
      File.cp!(src, Path.join(dir, "mix.lock"))

      case Cmd.mix(dir, ["deps.get"], env: [{"MIX_ENV", project["mix_env"]}]) do
        {:ok, _output} ->
          %{name: name, status: "applied", bumped: bumped}

        {:error, status, output} ->
          # The lockfile was copied but `deps.get` could not materialize it. Don't report
          # this as "applied" — surface it so the failure isn't silently swallowed.
          %{
            name: name,
            status: "deps_get_failed",
            bumped: bumped,
            error: "exit #{status}\n#{output}"
          }
      end
    else
      %{name: name, status: "missing_lock", bumped: bumped}
    end
  end

  defp filter_projects(projects, []), do: projects
  defp filter_projects(projects, only), do: Enum.filter(projects, &(&1["name"] in only))

  @spec raise_no_locks() :: no_return()
  defp raise_no_locks do
    Mix.raise(
      "The report has no captured lockfiles (\"verified_locks_dir\"). Re-run the bump " <>
        "to produce one, then apply it."
    )
  end

  @doc """
  Prints a human-readable summary of an apply run.
  """
  @spec print_summary(map()) :: :ok
  def print_summary(summary) do
    shell = Mix.shell()
    shell.info("\n" <> String.duplicate("─", 60))
    shell.info([:bright, "Applied verified lockfiles", :reset])

    Enum.each(summary.projects, fn project ->
      color = if project.status == "applied", do: :green, else: :red

      shell.info([
        "  ",
        color,
        "#{project.name}: #{project.status} (#{project.bumped} bump(s))",
        :reset
      ])
    end)

    shell.info(String.duplicate("─", 60))
    :ok
  end
end
