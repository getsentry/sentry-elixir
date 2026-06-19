defmodule Sentry.Dev.Cmd do
  @moduledoc """
  Runs `mix` subprocesses for `mix sentry.bump_lockfiles`, capturing output and exit codes.

  Each project is operated on as a separate OS process so that exit codes are
  unambiguous (compile failures vs test failures vs locked-deps failures). Output is
  captured for the JSON report and, when `:verbose` is set, streamed live.

  Subprocesses are launched via `Port.open/2` (not `System.cmd/3`) so that a `:timeout`
  can actually terminate the running command: on expiry we send `SIGKILL` to the OS
  process. `System.cmd/3` offers no way to do this — a timed-out `mix test` would keep
  running detached and could corrupt the next attempt's `_build`.

  This module is dev/CI tooling and is not part of the public API.
  """

  @moduledoc since: "13.3.0"

  @typep result :: {:ok, String.t()} | {:error, non_neg_integer() | :timeout, String.t()}

  @doc """
  Runs `mix` with the given `args` in `dir`.

  Options:

    * `:env` - extra environment variables as `[{"KEY", "VALUE"}]`
    * `:verbose` - stream the output live as it arrives (default `false`)
    * `:timeout` - hard cap in seconds measured from launch; on expiry the OS process is
      killed with `SIGKILL` and `{:error, :timeout, output}` is returned
    * `:log_to` - a file path to append the captured output to, prefixed with a header
      identifying the command. Parent directories are created as needed.

  Returns `{:ok, output}` on exit status 0, `{:error, status, output}` otherwise.
  """
  @spec mix(Path.t(), [String.t()], keyword()) :: result()
  def mix(dir, args, opts \\ []), do: command("mix", dir, args, opts)

  # Generic runner behind `mix/3`, exposed only so the subprocess/timeout machinery can
  # be exercised in tests with a cheap executable like `sh` instead of a real `mix` run.
  @doc false
  @spec command(String.t(), Path.t(), [String.t()], keyword()) :: result()
  def command(executable, dir, args, opts \\ []) do
    result = run(executable, dir, args, opts)
    log(Keyword.get(opts, :log_to), dir, args, result)
    result
  end

  defp run(executable, dir, args, opts) do
    path =
      System.find_executable(executable) ||
        raise ArgumentError, "could not find executable on PATH: #{executable}"

    port =
      Port.open({:spawn_executable, path}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:args, args},
        {:cd, dir},
        {:env, env_charlists(Keyword.get(opts, :env))}
      ])

    ctx = %{
      port: port,
      deadline: deadline(Keyword.get(opts, :timeout)),
      verbose: Keyword.get(opts, :verbose, false),
      args: args
    }

    collect(ctx, [])
  end

  defp deadline(nil), do: :infinity
  defp deadline(seconds), do: System.monotonic_time(:millisecond) + seconds * 1000

  defp remaining(:infinity), do: :infinity
  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  defp collect(%{port: port} = ctx, acc) do
    receive do
      {^port, {:data, data}} ->
        if ctx.verbose, do: IO.write(data)
        collect(ctx, [data | acc])

      {^port, {:exit_status, 0}} ->
        {:ok, finalize(acc)}

      {^port, {:exit_status, status}} ->
        {:error, status, finalize(acc)}
    after
      remaining(ctx.deadline) ->
        kill(port)

        {:error, :timeout,
         finalize(acc) <> "\n[killed: timed out running mix #{Enum.join(ctx.args, " ")}]"}
    end
  end

  defp finalize(acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  # SIGKILL the OS process (after `mix`'s exec chain this is the BEAM running the suite),
  # then close the port and drain any straggler messages so they don't leak to the caller.
  defp kill(port) do
    _ =
      with {:os_pid, os_pid} <- Port.info(port, :os_pid) do
        System.cmd("kill", ["-KILL", Integer.to_string(os_pid)], stderr_to_stdout: true)
      end

    close(port)
    flush(port)
  end

  defp close(port) do
    if Port.info(port), do: Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  defp flush(port) do
    receive do
      {^port, _} -> flush(port)
    after
      0 -> :ok
    end
  end

  defp env_charlists(nil), do: []

  defp env_charlists(env),
    do: Enum.map(env, fn {key, value} -> {to_charlist(key), to_charlist(value)} end)

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
end
