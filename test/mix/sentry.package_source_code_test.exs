defmodule Mix.Tasks.Sentry.PackageSourceCodeTest do
  use ExUnit.Case, async: false

  setup do
    shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(shell) end)
  end

  test "packages source code into :sentry's priv directory" do
    expected_path =
      [Application.app_dir(:sentry), "priv", "sentry.map"]
      |> Path.join()
      |> Path.relative_to_cwd()

    assert :ok = Mix.Task.rerun("sentry.package_source_code")

    assert_receive {:mix_shell, :info, ["Wrote " <> _ = message]}
    assert message =~ expected_path

    assert {:ok, contents} = File.read(expected_path)

    assert %{"version" => 1, "files_map" => source_map} =
             :erlang.binary_to_term(contents, [:safe])

    assert Map.has_key?(source_map, "lib/mix/tasks/sentry.package_source_code.ex")
  end

  test "supports the --debug option" do
    assert :ok = Mix.Task.rerun("sentry.package_source_code", ["--debug"])

    assert {:messages,
            [
              {:mix_shell, :info, ["Loaded source code map" <> _]},
              {:mix_shell, :info, ["Encoded source code map" <> _]},
              {:mix_shell, :info, ["Wrote " <> _]}
            ]} = Process.info(self(), :messages)
  end
end
