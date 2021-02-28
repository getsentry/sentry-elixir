defmodule Sentry.Sources do
  alias Sentry.Config

  @moduledoc """
  This module is responsible for providing functionality that stores
  the text of source files during compilation for displaying the
  source code that caused an exception.

  ### Configuration
  There is configuration required to set up this functionality.  The options
  include `:enable_source_code_context`, `:root_source_code_paths`, `:context_lines`,
  `:source_code_exclude_patterns`, and `:source_code_path_pattern`. The options must
  be set at compile-time.

  * `:enable_source_code_context` - when `true`, enables reporting source code
    alongside exceptions.
  * `:root_source_code_paths` - List of paths from which to start recursively reading files from.
    Should usually be set to `[File.cwd!()]`. For umbrella applications you should list all your
    applications paths in this list (e.g. `["#{File.cwd!()}/apps/app_1", "#{File.cwd!()}/apps/app_2"]`.
  * `:context_lines` - The number of lines of source code before and after the line that
    caused the exception to be included.  Defaults to `3`.
  * `:source_code_exclude_patterns` - a list of Regex expressions used to exclude file paths that
    should not be stored or referenced when reporting exceptions.  Defaults to
    `[~r"/_build/", ~r"/deps/", ~r"/priv/"]`.
  * `:source_code_path_pattern` - a glob that is expanded to select files from the
    `:root_source_code_path`.  Defaults to `"**/*.ex"`.

  An example configuration:

      config :sentry,
        dsn: "https://public:secret@app.getsentry.com/1",
        enable_source_code_context: true,
        root_source_code_path: [File.cwd!()],
        context_lines: 5

  ### Source code storage

  The file contents are saved when Sentry is compiled, which can cause some
  complications. If a file is changed, and Sentry is not recompiled,
  it will still report old source code.

  The best way to ensure source code is up to date is to recompile Sentry
  itself via `mix deps.compile sentry --force`.  It's possible to create a Mix
  Task alias in `mix.exs` to do this.  The example below would allow one to
  run `mix.sentry_recompile && mix compile` which will force recompilation of Sentry so
  it has the newest source and then compile the project. The second `mix compile`
  is required due to Mix only invoking the same task once in an alias.

      defp aliases do
        [sentry_recompile: ["compile", "deps.compile sentry --force"]]
      end

  This is an important to note especially when building for production. If your
  build or deployment system caches prior builds, it may not recompile Sentry
  and could cause issues with reported source code being out of date.

  Due to Sentry reading the file system and defaulting to a recursive search
  of directories, it is important to check your configuration and compilation
  environment to avoid a folder recursion issue. Problems may be seen when
  deploying to the root folder, so it is best to follow the practice of
  compiling your application in its own folder. Modifying the
  `source_code_path_pattern` configuration option from its default is also
  an avenue to avoid compile problems.

  """
  @type file_map :: %{pos_integer() => String.t()}
  @type source_map :: %{String.t() => file_map}

  def load_files do
    Enum.reduce(
      Config.root_source_code_paths(),
      %{},
      &load_files_for_root_path/2
    )
  end

  @doc """
  Given the source code map, a filename and a line number, this method retrieves the source code context.

  When reporting source code context to the Sentry API, it expects three separate values.  They are the source code
  for the specific line the error occurred on, the list of the source code for the lines preceding, and the
  list of the source code for the lines following.  The number of lines in the lists depends on what is
  configured in `:context_lines`.  The number configured is how many lines to get on each side of the line that
  caused the error.  If it is configured to be `3`, the method will attempt to get the 3 lines preceding, the
  3 lines following, and the line that the error occurred on, for a possible maximum of 7 lines.

  The three values are returned in a three element tuple as `{preceding_source_code_list, source_code_from_error_line, following_source_code_list}`.
  """
  @spec get_source_context(source_map, String.t(), pos_integer()) ::
          {[String.t()], String.t() | nil, [String.t()]}
  def get_source_context(files, file_name, line_number) do
    context_lines = Config.context_lines()
    file = Map.get(files, file_name)

    do_get_source_context(file, line_number, context_lines)
  end

  defp do_get_source_context(nil, _, _), do: {[], nil, []}

  defp do_get_source_context(file, line_number, context_lines) do
    context_line_indices = 0..(2 * context_lines)

    Enum.reduce(context_line_indices, {[], nil, []}, fn i, {pre_context, context, post_context} ->
      context_line_number = line_number - context_lines + i
      source = Map.get(file, context_line_number)

      cond do
        context_line_number == line_number && source ->
          {pre_context, source, post_context}

        context_line_number < line_number && source ->
          {pre_context ++ [source], context, post_context}

        context_line_number > line_number && source ->
          {pre_context, context, post_context ++ [source]}

        true ->
          {pre_context, context, post_context}
      end
    end)
  end

  defp load_files_for_root_path(root_path, files) do
    root_path
    |> find_files_for_root_path()
    |> Enum.reduce(files, fn path, acc ->
      key = Path.relative_to(path, root_path)

      if Map.has_key?(acc, key) do
        raise RuntimeError, """
        Found two source files in different source root paths with the same relative \
        path: #{key}

        This means that both source files would be reported to Sentry as the same \
        file. Please rename one of them to avoid this.
        """
      else
        value = source_to_lines(File.read!(path))

        Map.put(acc, key, value)
      end
    end)
  end

  defp find_files_for_root_path(root_path) do
    path_pattern = Config.source_code_path_pattern()
    exclude_patterns = Config.source_code_exclude_patterns()

    Path.join(root_path, path_pattern)
    |> Path.wildcard()
    |> exclude_files(exclude_patterns)
  end

  defp exclude_files(file_names, []), do: file_names

  defp exclude_files(file_names, [exclude_pattern | rest]) do
    Enum.reject(file_names, &String.match?(&1, exclude_pattern))
    |> exclude_files(rest)
  end

  defp source_to_lines(source) do
    String.replace_suffix(source, "\n", "")
    |> String.split("\n")
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn {line_string, line_number}, acc ->
      Map.put(acc, line_number + 1, line_string)
    end)
  end
end
