defmodule Mix.Tasks.Sentry.PackageSourceCodeTest do
  use Sentry.Case, async: false

  import Sentry.TestHelpers

  setup do
    set_mix_shell(Mix.Shell.Process)
  end

  test "packages source code into :sentry's priv directory" do
    put_test_config(
      root_source_code_paths: [File.cwd!()],
      enable_source_code_context: true
    )

    expected_path =
      [Application.app_dir(:sentry), "priv", "sentry.map"]
      |> Path.join()
      |> Path.relative_to_cwd()

    assert :ok = Mix.Task.rerun("sentry.package_source_code")

    validate_map_file!(expected_path)
  end

  @tag :tmp_dir
  test "packages source code into custom path", %{tmp_dir: tmp_dir} do
    put_test_config(
      root_source_code_paths: [File.cwd!()],
      enable_source_code_context: true
    )

    expected_path =
      [tmp_dir, "sentry.map"]
      |> Path.join()
      |> Path.relative_to_cwd()

    assert :ok = Mix.Task.rerun("sentry.package_source_code", ["--output", expected_path])

    validate_map_file!(expected_path)
  end

  test "supports the --debug option" do
    # Use a path pattern that doesn't match any files, to make this test as fast as
    # possible.
    old_root_source_code_paths = Application.get_env(:sentry, :root_source_code_paths)

    on_exit(fn ->
      Application.put_env(:sentry, :root_source_code_paths, old_root_source_code_paths)
    end)

    Application.put_env(:sentry, :root_source_code_paths, [])

    assert :ok = Mix.Task.rerun("sentry.package_source_code", ["--debug"])

    assert {:messages,
            [
              {:mix_shell, :info, ["Loaded source code map" <> _]},
              {:mix_shell, :info, ["Encoded source code map" <> _]},
              {:mix_shell, :info, ["Wrote " <> _]}
            ]} = Process.info(self(), :messages)
  end

  defp validate_map_file!(path) do
    assert_receive {:mix_shell, :info, ["Wrote " <> _ = message]}
    assert message =~ path

    assert {:ok, contents} = File.read(path)

    assert %{"version" => 1, "files_map" => source_map} =
             :erlang.binary_to_term(contents, [:safe])

    assert Map.has_key?(source_map, "lib/mix/tasks/sentry.package_source_code.ex")
  end
end
