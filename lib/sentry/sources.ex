defmodule Sentry.Sources do
  @moduledoc false

  alias Sentry.Config

  @type source_map :: %{
          optional(String.t()) => %{
            (line_no :: pos_integer()) => line_contents :: String.t()
          }
        }

  @source_code_map_key {:sentry, :source_code_map}
  @compression_level if Mix.env() == :test, do: 0, else: 9

  # Default argument is here for testing.
  @spec load_source_code_map_if_present(Path.t() | nil) ::
          {:loaded, source_map()} | {:error, term()}
  def load_source_code_map_if_present(path_for_tests \\ nil) do
    path = path_for_tests || Config.source_code_map_path() || path_of_packaged_source_code()
    path = Path.relative_to_cwd(path)

    with {:ok, contents} <- File.read(path),
         {:ok, source_map} <- decode_source_code_map(contents) do
      :persistent_term.put(@source_code_map_key, source_map)
      {:loaded, source_map}
    else
      {:error, :binary_to_term} ->
        IO.warn("""
        Sentry found a source code map file at #{path}, but it was unable to decode its
        contents.
        """)

        {:error, :decoding_error}

      {:error, :enoent} ->
        {:error, :enoent}

      {:error, reason} ->
        IO.warn("""
        Sentry found a source code map file at #{path}, but it was unable to read it.
        The reason was: #{:file.format_error(reason)}
        """)

        {:error, reason}
    end
  end

  @spec path_of_packaged_source_code() :: Path.t()
  def path_of_packaged_source_code do
    Path.join([Application.app_dir(:sentry), "priv", "sentry.map"])
  end

  @spec encode_source_code_map(source_map()) :: binary()
  def encode_source_code_map(%{} = source_map) do
    # This term contains no atoms, so that it can be decoded with binary_to_term(bin, [:safe]).
    term_to_encode = %{"version" => 1, "files_map" => source_map}
    :erlang.term_to_binary(term_to_encode, compressed: @compression_level)
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

  @spec load_files(keyword()) :: {:ok, source_map()} | {:error, message :: String.t()}
  def load_files(config \\ []) when is_list(config) do
    config = Sentry.Config.validate!(config)

    path_pattern = Keyword.fetch!(config, :source_code_path_pattern)
    exclude_patterns = Keyword.fetch!(config, :source_code_exclude_patterns)

    config
    |> Keyword.fetch!(:root_source_code_paths)
    |> Enum.reduce(%{}, &load_files_for_root_path(&1, &2, path_pattern, exclude_patterns))
    |> Map.new(fn {path, %{lines: lines}} -> {path, lines} end)
  catch
    {:same_relative_path, path, root_path1, root_path2} ->
      message = """
      Found two source files in different source root paths with the same relative path:

        1. #{root_path1 |> Path.join(path) |> Path.relative_to_cwd()}
        2. #{root_path2 |> Path.join(path) |> Path.relative_to_cwd()}

      The part of those paths that causes the conflict is:

        #{path}

      Sentry cannot report the right source code context if this happens, because
      it won't be able to retrieve the correct file from exception stacktraces.

      To fix this, you'll have to rename one of the conflicting paths.
      """

      {:error, message}
  else
    source_map -> {:ok, source_map}
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

      case Map.fetch(acc, key) do
        :error ->
          value = %{lines: source_to_lines(File.read!(path)), root_path: root_path}
          Map.put(acc, key, value)

        {:ok, %{root_path: existing_root_path}} ->
          throw({:same_relative_path, key, root_path, existing_root_path})
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
