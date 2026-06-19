defmodule Sentry.Dev.Cmd do
  @moduledoc """
  Runs `mix` subprocesses for `mix sentry.bump_lockfiles`, capturing output and exit codes.

  Each project is operated on as a separate OS process so that exit codes are
  unambiguous (compile failures vs test failures vs locked-deps failures). Output is
  captured for the JSON report and, when `:verbose` is set, echoed once the command
  finishes.

  This module is dev/CI tooling and is not part of the public API.
  """

  @moduledoc since: "13.3.0"

  @doc """
  Runs `mix` with the given `args` in `dir`.

  Options:

    * `:env` - extra environment variables as `[{"KEY", "VALUE"}]`
    * `:verbose` - echo the captured output once the command finishes (default `false`)
    * `:timeout` - hard cap in seconds; on expiry the process is killed and
      `{:error, :timeout, output}` is returned
    * `:log_to` - a file path to append the captured output to, prefixed with a header
      identifying the command. Parent directories are created as needed.

  Returns `{:ok, output}` on exit status 0, `{:error, status, output}` otherwise.
  """
  @spec mix(Path.t(), [String.t()], keyword()) ::
          {:ok, String.t()} | {:error, non_neg_integer() | :timeout, String.t()}
  def mix(dir, args, opts \\ []) do
    result =
      case Keyword.get(opts, :timeout) do
        nil -> run(dir, args, opts)
        seconds -> run_with_timeout(dir, args, opts, seconds)
      end

    log(Keyword.get(opts, :log_to), dir, args, result)
    result
  end

  defp log(nil, _dir, _args, _result), do: :ok

  defp log(path, dir, args, result) do
    {status, output} =
      case result do
        {:ok, out} -> {0, out}
        {:error, status, out} -> {status, out}
      end

    File.mkdir_p!(Path.dirname(path))
    header = "\n===== #{dir} $ mix #{Enum.join(args, " ")} (exit #{status}) =====\n"
    File.write!(path, header <> output, [:append])
  end

  defp run_with_timeout(dir, args, opts, seconds) do
    task = Task.async(fn -> run(dir, args, opts) end)

    case Task.yield(task, seconds * 1000) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} ->
        result

      nil ->
        {:error, :timeout, "Command timed out after #{seconds}s: mix #{Enum.join(args, " ")}"}
    end
  end

  defp run(dir, args, opts) do
    cmd_opts = [cd: dir, stderr_to_stdout: true]
    cmd_opts = maybe_put_env(cmd_opts, Keyword.get(opts, :env))

    {output, status} = System.cmd("mix", args, cmd_opts)

    if Keyword.get(opts, :verbose, false), do: IO.write(output)

    if status == 0, do: {:ok, output}, else: {:error, status, output}
  end

  defp maybe_put_env(cmd_opts, nil), do: cmd_opts
  defp maybe_put_env(cmd_opts, env), do: Keyword.put(cmd_opts, :env, env)
end
