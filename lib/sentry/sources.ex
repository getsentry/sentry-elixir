defmodule Sentry.Sources do
  @moduledoc false

  alias Sentry.Config

  @type source_map :: %{
          optional(String.t()) => %{
            (line_no :: pos_integer()) => line_contents :: String.t()
          }
        }

  @source_code_map_key {:sentry, :source_code_map}

  @spec load_source_code_map_if_present() :: :ok
  def load_source_code_map_if_present do
    path = Path.relative_to_cwd(path_of_packaged_source_code())

    with {:ok, contents} <- File.read(path),
         {:ok, source_map} <- decode_source_code_map(contents) do
      :persistent_term.put(@source_code_map_key, source_map)
    else
      {:error, :binary_to_term} ->
        IO.warn("""
        Sentry found a source code map file at #{path}, but it was unable to decode its
        contents.
        """)

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        IO.warn("""
        Sentry found a source code map file at #{path}, but it was unable to read it.
        The reason was: #{:file.format_error(reason)}
        """)
    end

    :ok
  end

  @spec path_of_packaged_source_code() :: Path.t()
  def path_of_packaged_source_code do
    Path.join([Application.app_dir(:sentry), "priv", "sentry.map"])
  end

  @spec encode_source_code_map(source_map()) :: binary()
  def encode_source_code_map(%{} = source_map) do
    # This term contains no atoms, so that it can be decoded with binary_to_term(bin, [:safe]).
    term_to_encode = %{"version" => 1, "files_map" => source_map}
    :erlang.term_to_binary(term_to_encode, compressed: 9)
  end

  defp decode_source_code_map(binary) when is_binary(binary) do
    try do
      :erlang.binary_to_term(binary, [:safe])
    rescue
      ArgumentError -> {:error, :binary_to_term}
    else
      %{"version" => 1, "files_map" => source_map} -> {:ok, source_map}
    end
  end

  @spec get_source_code_map_from_persistent_term() :: source_map() | nil
  def get_source_code_map_from_persistent_term do
    :persistent_term.get(@source_code_map_key, nil)
  end

  @spec load_files([Path.t()]) :: source_map()
  def load_files(paths \\ Config.root_source_code_paths()) when is_list(paths) do
    path_pattern = Config.source_code_path_pattern()
    exclude_patterns = Config.source_code_exclude_patterns()

    Enum.reduce(paths, %{}, &load_files_for_root_path(&1, &2, path_pattern, exclude_patterns))
  end

  @spec get_source_context(source_map(), String.t() | nil, pos_integer() | nil) ::
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

  defp load_files_for_root_path(root_path, files, path_pattern, exclude_patterns) do
    root_path
    |> find_files_for_root_path(path_pattern, exclude_patterns)
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

  defp find_files_for_root_path(root_path, path_pattern, exclude_patterns) do
    root_path
    |> Path.join(path_pattern)
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
