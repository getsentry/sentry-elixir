defmodule Sentry.Sources do
  @moduledoc false

  alias Sentry.Config

  @type source_map :: %{
          optional(String.t()) => %{
            (line_no :: pos_integer()) => line_contents :: String.t()
          }
        }

  @spec load_files([Path.t()]) :: source_map()
  def load_files(paths \\ Config.root_source_code_paths()) do
    Enum.reduce(paths, %{}, &load_files_for_root_path/2)
  end

  @spec get_source_context(source_map, String.t() | nil, pos_integer() | nil) ::
          {[String.t()], String.t() | nil, [String.t()]}
  def get_source_context(%{} = files, file_name, line_number) do
    context_lines = Config.context_lines()

    case Map.fetch(files, file_name) do
      :error -> {[], nil, []}
      {:ok, file} -> get_source_context_for_file(file, line_number, context_lines)
    end
  end

  defp get_source_context_for_file(file, line_number, context_lines) do
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
