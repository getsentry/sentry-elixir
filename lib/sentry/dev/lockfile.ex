defmodule Sentry.Dev.Lockfile do
  @moduledoc """
  Reads and diffs `mix.lock` files for the `mix sentry.bump_lockfiles` task.

  A `mix.lock` is an Elixir map literal mapping a dependency name to a tuple. Hex
  dependencies look like `{:hex, :name, "1.2.3", "hash", build_tools, deps, "hexpm",
  "outer_hash"}` — the version lives at element 2. Git and path dependencies use a
  different tuple shape and carry no comparable version, so they are skipped.

  This module is dev/CI tooling and is not part of the public API.
  """

  @moduledoc since: "13.3.0"

  @type lock :: %{optional(String.t()) => tuple()}
  @type change :: %{dep: String.t(), from: String.t(), to: String.t()}

  @doc """
  Parses a `mix.lock` file into a map of dependency name (string) to lock entry.

  The file is *parsed*, never evaluated: `Code.string_to_quoted/2` turns it into an AST,
  which is then converted to a term while rejecting anything that is not a plain data
  literal. This keeps a malicious or malformed `mix.lock` from executing code (a real
  risk since the lock is otherwise indistinguishable from Elixir source).

  A `mix.lock` literal uses keyword syntax (`"dep": {...}`), so its keys parse to atoms;
  they are normalized to strings here. Returns an empty map if the file does not exist
  (a project may have no lock yet).
  """
  @spec read(Path.t()) :: lock()
  def read(path) do
    if File.exists?(path) do
      path
      |> File.read!()
      |> parse()
      |> Map.new(fn {name, entry} -> {to_string(name), entry} end)
    else
      %{}
    end
  end

  defp parse(contents) do
    # `emit_warnings: false` silences the "quoted keyword" warning mix.lock entries
    # trigger. `string_to_quoted` only parses — it does not run the contents.
    case Code.string_to_quoted(contents, emit_warnings: false) do
      {:ok, ast} -> to_term(ast)
      {:error, reason} -> raise ArgumentError, "could not parse mix.lock: #{inspect(reason)}"
    end
  end

  # Convert a literal-only AST into a term. Maps, tuples, lists, and scalars are allowed;
  # anything else (a function call, a variable — i.e. executable code) is rejected.
  defp to_term({:%{}, _meta, pairs}),
    do: Map.new(pairs, fn {k, v} -> {to_term(k), to_term(v)} end)

  defp to_term({:{}, _meta, elems}), do: elems |> Enum.map(&to_term/1) |> List.to_tuple()
  defp to_term({left, right}), do: {to_term(left), to_term(right)}
  defp to_term(list) when is_list(list), do: Enum.map(list, &to_term/1)
  defp to_term(scalar) when is_atom(scalar) or is_binary(scalar) or is_number(scalar), do: scalar

  defp to_term(other) do
    raise ArgumentError, "mix.lock contains a non-literal expression: #{inspect(other)}"
  end

  @doc """
  Extracts the version string from a hex lock entry.

  Returns `:not_hex` for git/path entries, which have no comparable version.
  """
  @spec hex_version(tuple()) :: {:ok, String.t()} | :not_hex
  def hex_version({:hex, _name, version, _hash, _build_tools, _deps, _repo, _outer_hash})
      when is_binary(version),
      do: {:ok, version}

  def hex_version({:hex, _name, version, _hash, _build_tools, _deps, _repo})
      when is_binary(version),
      do: {:ok, version}

  def hex_version(_other), do: :not_hex

  @doc """
  Returns the version changes between two parsed locks.

  Only hex dependencies whose version differs are reported. Each change is
  `%{dep: name, from: old_version, to: new_version}`. Dependencies that only exist
  in the new lock are reported with `from: nil`.
  """
  @spec diff(lock(), lock()) :: [change()]
  def diff(old_lock, new_lock) do
    new_lock
    |> Enum.flat_map(fn {name, new_entry} ->
      with {:ok, new_version} <- hex_version(new_entry),
           false <- new_version == old_version(old_lock, name) do
        [%{dep: name, from: old_version(old_lock, name), to: new_version}]
      else
        _ -> []
      end
    end)
    |> Enum.sort_by(& &1.dep)
  end

  defp old_version(lock, name) do
    case Map.fetch(lock, name) do
      {:ok, entry} ->
        case hex_version(entry) do
          {:ok, version} -> version
          :not_hex -> nil
        end

      :error ->
        nil
    end
  end
end
