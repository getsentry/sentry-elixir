defmodule Sentry.Dev.Report do
  @moduledoc """
  Builds, encodes, and prints the JSON report for `mix sentry.bump_lockfiles`.

  This module is dev/CI tooling and is not part of the public API.
  """

  @moduledoc since: "13.3.0"

  @schema_version 1

  @doc """
  Wraps the bumper result in report metadata and a summary.
  """
  @spec build(map()) :: map()
  def build(result) do
    result
    |> Map.put(:schema_version, @schema_version)
    |> Map.put(:generated_at, DateTime.utc_now() |> DateTime.to_iso8601())
    |> Map.put(:elixir_version, System.version())
    |> Map.put(:otp_version, otp_version())
    |> Map.put(:summary, summary(result))
  end

  @doc """
  Encodes the report as pretty-printed JSON.
  """
  @spec encode(map()) :: String.t()
  def encode(report) do
    if Code.ensure_loaded?(Jason) do
      Jason.encode!(report, pretty: true)
    else
      Mix.raise("Jason is required to encode the report but is not available")
    end
  end

  @doc """
  Writes the encoded report to `path`, creating parent directories as needed.
  """
  @spec write(map(), Path.t()) :: :ok
  def write(report, path) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, encode(report))
  end

  @doc """
  Reads and decodes a previously written report from `path` (string-keyed map).
  """
  @spec read(Path.t()) :: map()
  def read(path) do
    if Code.ensure_loaded?(Jason) do
      path |> File.read!() |> Jason.decode!()
    else
      Mix.raise("Jason is required to read the report but is not available")
    end
  end

  @doc """
  Prints a colored, human-readable summary of the report.
  """
  @spec print_summary(map()) :: :ok
  def print_summary(report) do
    summary = report.summary
    shell = Mix.shell()

    shell.info("\n" <> String.duplicate("─", 60))
    shell.info([:bright, "Dependency bump report", :reset])

    shell.info([
      "Overall status: ",
      status_color(report.overall_status),
      report.overall_status,
      :reset
    ])

    shell.info(
      "Bumped: #{summary.bumped}  •  Skipped (major): #{summary.skipped_major}  •  Failed: #{summary.failed}"
    )

    Enum.each(report.projects, &print_project(&1, shell))
    shell.info(String.duplicate("─", 60))
    :ok
  end

  defp print_project(project, shell) do
    shell.info(["\n", :bright, project.name, :reset, " (#{project.status})"])

    Enum.each(project.bumped, fn b ->
      shell.info(["  ", :green, "✓ #{b.dep} #{b.from} -> #{b.to}", :reset])
    end)

    Enum.each(project.skipped_major, fn s ->
      shell.info([
        "  ",
        :yellow,
        "⤳ #{s.dep} #{s.from} -> #{s.to} (skipped: #{s.reason})",
        :reset
      ])
    end)

    Enum.each(project.failed, fn f ->
      shell.info([
        "  ",
        :red,
        "✗ #{f.dep} #{f.from} -> #{f.to} (#{f.failure_type} in #{f.manifested_in})",
        :reset
      ])
    end)
  end

  defp summary(result) do
    projects = result.projects

    %{
      projects: length(projects),
      bumped: count(projects, :bumped),
      skipped_major: count(projects, :skipped_major),
      failed: count(projects, :failed),
      optimistic_passed: result.optimistic_passed,
      full_validation_passed: result.full_validation_passed
    }
  end

  defp count(projects, key),
    do: Enum.reduce(projects, 0, fn p, acc -> acc + length(Map.fetch!(p, key)) end)

  defp status_color("green"), do: :green
  defp status_color("partial"), do: :yellow
  defp status_color("failed"), do: :red

  defp otp_version do
    case :file.read_file(
           Path.join([
             :code.root_dir(),
             "releases",
             :erlang.system_info(:otp_release),
             "OTP_VERSION"
           ])
         ) do
      {:ok, version} -> String.trim(version)
      _ -> List.to_string(:erlang.system_info(:otp_release))
    end
  end
end
