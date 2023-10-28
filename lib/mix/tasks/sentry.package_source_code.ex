defmodule Mix.Tasks.Sentry.PackageSourceCode do
  @moduledoc """
  TODO
  """

  @shortdoc "TODO"

  use Mix.Task

  alias Sentry.{Config, Sources}

  @bytes_in_kb 1024
  @bytes_in_mb 1024 * 1024
  @bytes_in_gb 1024 * 1024 * 1024

  @switches [debug: :boolean]

  @impl true
  def run(args) do
    {opts, _args} = OptionParser.parse!(args, strict: @switches)

    output_dir = Application.app_dir(:sentry, "priv")
    root_paths = Config.root_source_code_paths()

    {elapsed, files_map} = :timer.tc(fn -> Sources.load_files(root_paths) end)

    log_debug(
      opts,
      "Loaded source code map with #{map_size(files_map)} files in #{format_time(elapsed)}"
    )

    term = %{
      version: 1,
      files_map: files_map
    }

    output_path = Path.join(output_dir, "sentry.map")

    {elapsed, contents} = :timer.tc(fn -> :erlang.term_to_binary(term, [:compressed]) end)
    log_debug(opts, "Encoded source code map in #{format_time(elapsed)}")

    File.mkdir_p!(Path.dirname(output_path))
    File.write!(output_path, contents)

    Mix.shell().info([
      "Wrote ",
      :cyan,
      format_bytes(byte_size(contents)),
      :reset,
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
