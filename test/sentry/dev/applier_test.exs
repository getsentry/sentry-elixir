defmodule Sentry.Dev.ApplierTest do
  use ExUnit.Case, async: true

  alias Sentry.Dev.Applier

  defp report(projects, locks_dir) do
    %{
      "generated_at" => "2026-06-12T00:00:00Z",
      "verified_locks_dir" => locks_dir,
      "projects" => projects
    }
  end

  defp project(name, dir, bumped \\ []) do
    %{"name" => name, "dir" => dir, "mix_env" => "test", "bumped" => bumped}
  end

  test "raises when the report has no captured lockfiles" do
    report = %{"projects" => [], "verified_locks_dir" => nil}

    assert_raise Mix.Error, ~r/no captured lockfiles/, fn ->
      Applier.apply(report, [])
    end
  end

  test "reports missing_lock when the sidecar lockfile is absent" do
    empty_dir = Path.join(System.tmp_dir!(), "applier_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(empty_dir)
    on_exit(fn -> File.rm_rf!(empty_dir) end)

    report = report([project("root", ".", [%{"dep" => "plug"}])], empty_dir)
    summary = Applier.apply(report, [])

    assert summary.all_applied? == false
    assert [%{name: "root", status: "missing_lock", bumped: 1}] = summary.projects
  end

  test "filters to the requested projects" do
    empty_dir = Path.join(System.tmp_dir!(), "applier_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(empty_dir)
    on_exit(fn -> File.rm_rf!(empty_dir) end)

    report =
      report(
        [project("root", "."), project("phoenix_app", "test_integrations/phoenix_app")],
        empty_dir
      )

    summary = Applier.apply(report, projects: "phoenix_app")

    assert [%{name: "phoenix_app"}] = summary.projects
  end
end
