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

  A `mix.lock` literal uses keyword syntax (`"dep": {...}`), so its keys evaluate to
  atoms; they are normalized to strings here. Returns an empty map if the file does not
  exist (a project may have no lock yet).
  """
  @spec read(Path.t()) :: lock()
  def read(path) do
    if File.exists?(path) do
      {lock, _bindings} = eval(path)
      Map.new(lock, fn {name, entry} -> {to_string(name), entry} end)
    else
      %{}
    end
  end

  # `Code.eval_file/1` prints a "quoted keyword" warning for every lock entry. When
  # available, capture those diagnostics instead of flooding the task output.
  defp eval(path) do
    if function_exported?(Code, :with_diagnostics, 1) do
      {result, _diagnostics} = Code.with_diagnostics(fn -> Code.eval_file(path) end)
      result
    else
      Code.eval_file(path)
    end
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
