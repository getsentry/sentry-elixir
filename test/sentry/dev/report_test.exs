defmodule Sentry.Dev.ReportTest do
  use ExUnit.Case, async: true

  alias Sentry.Dev.Report

  defp result do
    %{
      optimistic_passed: false,
      full_validation_passed: true,
      overall_status: "partial",
      options: %{allow_major: false},
      projects: [
        %{
          name: "root",
          dir: ".",
          mix_env: "test",
          optimistic_passed: false,
          status: "partial",
          bumped: [%{dep: "plug", from: "1.16.0", to: "1.17.0", also_changed: []}],
          skipped_major: [
            %{dep: "floki", from: "0.36.0", to: "0.37.0", reason: "0x_minor_breaking"}
          ],
          failed: [
            %{
              dep: "phoenix_live_view",
              from: "0.20.0",
              to: "1.0.0",
              failure_type: "tests",
              attributed_to: "root",
              manifested_in: "phoenix_app",
              kept_at: "0.20.0",
              log_snippet: "boom"
            }
          ]
        }
      ]
    }
  end

  describe "build/1" do
    test "adds schema metadata and a summary with correct counts" do
      report = Report.build(result())

      assert report.schema_version == 1
      assert is_binary(report.generated_at)
      assert report.elixir_version == System.version()
      assert report.summary.projects == 1
      assert report.summary.bumped == 1
      assert report.summary.skipped_major == 1
      assert report.summary.failed == 1
      assert report.summary.full_validation_passed == true
    end
  end

  describe "encode/1" do
    test "produces valid JSON that round-trips" do
      report = Report.build(result())
      json = Report.encode(report)

      assert {:ok, decoded} = Jason.decode(json)
      assert decoded["overall_status"] == "partial"
      assert decoded["summary"]["bumped"] == 1
      assert [project] = decoded["projects"]
      assert project["name"] == "root"
      assert hd(project["failed"])["failure_type"] == "tests"
    end
  end

  describe "write/2" do
    test "writes the encoded report to disk" do
      path =
        Path.join(System.tmp_dir!(), "report_test_#{System.unique_integer([:positive])}.json")

      on_exit(fn -> File.rm(path) end)

      Report.write(result() |> Report.build(), path)

      assert File.exists?(path)
      assert {:ok, _} = path |> File.read!() |> Jason.decode()
    end
  end
end
