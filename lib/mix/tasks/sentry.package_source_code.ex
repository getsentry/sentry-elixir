defmodule Mix.Tasks.Sentry.PackageSourceCode do
  @shortdoc "Packages source code for Sentry to use when reporting errors"

  @moduledoc """
  Packages source code for Sentry to use when reporting errors.

  This task should be used in production settings, before building a release of your
  application. It packages all the source code of your application in a single file
  (called `sentry.map`), which is optimized for fast retrieval of source code lines.
  Sentry then uses this to report source code context. See the documentation for the
  `Sentry` module for configuration options related to the source code context.

  *This task is available since v10.0.0 of this library*.

  ## Usage

  ```shell
  mix sentry.package_source_code
  ```

  ### Using in Production

  In production settings, call this task before building a release. This way, the source
  code packaged by this task will be included in the release.

  For example, in a release script (this could also be in a `Dockerfile`, if you're using
  Docker):

  ```shell
  # ...

  mix sentry.package_source_code
  mix release
  ```

  > #### Runtime Configuration {: .tip}
  >
  > If you use `config/runtime.exs` for runtime configuration of your application and
  > release, *and* you also configure the source-context-related options for the `:sentry`
  > application in that file (such as `:root_source_code_paths`), you'll need to call the
  > `mix app.config` task before calling this Mix task. `mix app.config` loads the
  > `config/runtime.exs` configuration. Generally, we recommend configuring all the
  > source-context-related options in compile-time config files (like `config/config.exs`
  > or `config/prod.exs`).

  ## Options

    * `--debug` - print more information about collecting and encoding source code
    * `--output PATH` - write source map file to the given `PATH`. If you don't specify
      this option, the file will be written to the default path, which is inside the `priv`
      directory of the `:sentry` application. If you use this option, remember to also
      **configure the `:source_code_map_path` option**, otherwise Sentry will try to
      *read* the file from the default location. See `Sentry` for more information.
      This option can be useful when the source
      `priv` directory is read-only, such as with [NixOS](https://github.com/NixOS/nixpkgs)
      and similar tools.
      *Available since v10.2.0*.

  """

  @moduledoc since: "10.0.0"

  use Mix.Task

  alias Sentry.Sources

  @bytes_in_kb 1024
  @bytes_in_mb 1024 * 1024
  @bytes_in_gb 1024 * 1024 * 1024

  @switches [
    debug: :boolean,
    output: :string
  ]

  @impl true
  def run(args) do
    {opts, _args} = OptionParser.parse!(args, strict: @switches)

    config = Application.get_all_env(:sentry)

    {elapsed, source_map} =
      :timer.tc(fn ->
        case Sources.load_files(config) do
          {:ok, source_map} -> source_map
          {:error, message} -> Mix.raise(message)
        end
      end)

    log_debug(
      opts,
      "Loaded source code map with #{map_size(source_map)} files in #{format_time(elapsed)}"
    )

    {elapsed, contents} = :timer.tc(fn -> Sources.encode_source_code_map(source_map) end)
    log_debug(opts, "Encoded source code map in #{format_time(elapsed)}")

    output_path = Keyword.get_lazy(opts, :output, &Sources.path_of_packaged_source_code/0)
    File.mkdir_p!(Path.dirname(output_path))
    File.write!(output_path, contents)

    Mix.shell().info([
      "Wrote #{map_size(source_map)} files in ",
      [:cyan, format_bytes(byte_size(contents)), :reset],
      " to: #{Path.relative_to_cwd(output_path)}"
    ])
  end

  ## Helpers

  defp log_debug(opts, str) do
    if opts[:debug] do
      Mix.shell().info([:magenta, str, :reset])
    end
  end

  defp format_bytes(n) when n < @bytes_in_kb, do: "#{n} bytes"
  defp format_bytes(n) when n < @bytes_in_mb, do: "#{Float.round(n / @bytes_in_kb, 2)} kb"
  defp format_bytes(n) when n < @bytes_in_gb, do: "#{Float.round(n / @bytes_in_mb, 2)} Mb"

  defp format_time(n) when n < 1000, do: "#{n} µs"
  defp format_time(n) when n < 1_000_000, do: "#{div(n, 1000)} ms"
  defp format_time(n), do: "#{Float.round(n / 1_000_000, 2)} s"
end
