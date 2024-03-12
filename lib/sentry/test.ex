defmodule Sentry.Test do
  @moduledoc """
  Utilities for testing Sentry reports.

  ## Usage

  This module is based on **collecting** reported events and then retrieving
  them to perform assertions. The functionality here is only available if the
  `:test_mode` configuration option is set to `true`—see
  [`Sentry`'s configuration section](sentry.html#module-configuration).
  You can start collecting events from a process
  by calling `start_collecting_sentry_reports/0`. Then, you can use Sentry
  as normal and report events (through functions such as `Sentry.capture_message/1`
  or `Sentry.capture_exception/1`). Finally, you can retrieve the collected events
  by calling `pop_sentry_reports/0`.

  > #### Test Mode and DSN {: .info}
  >
  > If `:test_mode` is `true`, the `:dsn` option behaves differently. When `:dsn` is
  > not set or `nil` and you're collecting events, you'll still be able to collect
  > events—even if under normal circumstances a missing `:dsn` means events don't get
  > reported. If `:dsn` is `nil` and you're not collecting events, the event is simply
  > ignored. See the table below for a summary for this behavior.

  | `:test_mode` | `:dsn` | Collecting events? | Behavior                                               |
  |--------------|--------|--------------------|--------------------------------------------------------|
  | `true`       | `nil`  | yes                | Event is collected                                     |
  | `true`       | `nil`  | no                 | Event is ignored (silently)                            |
  | `true`       | set    | yes                | Event is collected                                     |
  | `true`       | set    | no                 | Makes HTTP request to configured DSN (could be Bypass) |
  | `false`      | `nil`  | irrelevant         | Ignores event                                          |
  | `false`      | set    | irrelevant         | Makes HTTP request to configured DSN (could be Bypass) |

  ## Examples

  Let's imagine writing a test using the functions in this module. First, we need to
  start collecting events:

      test "reporting from child processes" do
        parent_pid = self()

        # Collect reports from self().
        assert :ok = Test.start_collecting_sentry_reports()

        # <we'll fill this in below...>
      end

  Now, we can report events as normal. For example, we can report an event from the
  parent process:

      assert {:ok, ""} = Sentry.capture_message("Oops from parent process")

  We can also report events from "child" processes.

      # Spawn a child that waits for the :go message and then reports an event.
      {:ok, child_pid} =
        Task.start_link(fn ->
          receive do
            :go ->
              assert {:ok, ""} = Sentry.capture_message("Oops from child process")
              send(parent_pid, :done)
          end
        end)

      # Start the child and wait for it to finish.
      send(child_pid, :go)
      assert_receive :done

  Now, we can retrieve the collected events and perform assertions on them:

      assert [%Event{} = event1, %Event{} = event2] = Test.pop_sentry_reports()
      assert event1.message.formatted == "Oops from parent process"
      assert event2.message.formatted == "Oops from child process"

  """

  @moduledoc since: "10.2.0"

  @server __MODULE__.OwnershipServer
  @key :events

  # Used internally when reporting an event, *before* reporting the actual event.
  @doc false
  @spec maybe_collect(Sentry.Event.t()) :: :collected | :not_collecting
  def maybe_collect(%Sentry.Event{} = event) do
    if Sentry.Config.test_mode?() do
      dsn_set? = not is_nil(Sentry.Config.dsn())
      ensure_ownership_server_started()

      case NimbleOwnership.fetch_owner(@server, callers(), @key) do
        {:ok, owner_pid} ->
          result =
            NimbleOwnership.get_and_update(@server, owner_pid, @key, fn events ->
              {:collected, (events || []) ++ [event]}
            end)

          case result do
            {:ok, :collected} ->
              :collected

            {:error, error} ->
              raise ArgumentError, "cannot collect Sentry reports: #{Exception.message(error)}"
          end

        :error when dsn_set? ->
          :not_collecting

        # If the :dsn option is not set and we didn't capture the event, it's alright,
        # we can just swallow it.
        :error ->
          :collected
      end
    else
      :not_collecting
    end
  end

  @doc """
  Starts collecting events from the current process.

  This function starts collecting events reported from the current process. If you want to
  allow other processes to report events, you need to *allow* them to report events back
  to the current process. See `allow/2` for more information on allowances. If the current
  process is already *allowed by another process*, this function raises an error.

  The `context` parameter is ignored. It's there so that this function can be used
  as an ExUnit **setup callback**. For example:

      import Sentry.Test

      setup :start_collecting_sentry_reports

  For a more flexible way to start collecting events, see `start_collecting/1`.
  """
  @doc since: "10.2.0"
  @spec start_collecting_sentry_reports(map()) :: :ok
  def start_collecting_sentry_reports(_context \\ %{}) do
    start_collecting()
  end

  @doc """
  Starts collecting events.

  This function starts collecting events reported from the given (*owner*) process. If you want to
  allow other processes to report events, you need to *allow* them to report events back
  to the owner process. See `allow/2` for more information on allowances. If the owner
  process is already *allowed by another process*, this function raises an error.

  ## Options

    * `:owner` - the PID of the owner process that will collect the events. Defaults to `self/0`.

    * `:cleanup` - a boolean that controls whether collected resources around the owner process
      should be cleaned up when the owner process exits. Defaults to `true`. If `false`, you'll
      need to manually call `cleanup/1` to clean up the resources.

  ## Examples

  The `:cleanup` option can be used to implement expectation-based tests, akin to something
  like [`Mox.expect/4`](https://hexdocs.pm/mox/1.1.0/Mox.html#expect/4).

      test "implementing an expectation-based test workflow" do
        test_pid = self()

        Test.start_collecting(owner: test_pid, cleanup: false)

        on_exit(fn ->
          assert [%Event{} = event] = Test.pop_sentry_reports(test_pid)
          assert event.message.formatted == "Oops"
          assert :ok = Test.cleanup(test_pid)
        end)

        assert {:ok, ""} = Sentry.capture_message("Oops")
      end

  """
  @doc since: "10.2.0"
  @spec start_collecting(keyword()) :: :ok
  def start_collecting(options \\ []) when is_list(options) do
    owner_pid = Keyword.get(options, :owner, self())
    cleanup? = Keyword.get(options, :cleanup, true)

    callers =
      if owner_pid == self() do
        callers()
      else
        [owner_pid]
      end

    # Make sure the ownership server is started (this is idempotent).
    ensure_ownership_server_started()

    case NimbleOwnership.fetch_owner(@server, callers, @key) do
      # No-op
      {tag, ^owner_pid} when tag in [:ok, :shared_owner] ->
        :ok

      {:shared_owner, _other_pid} ->
        raise ArgumentError,
              "Sentry.Test is in global mode and is already collecting reported events"

      {:ok, other_pid} ->
        raise ArgumentError, "already collecting reported events from #{inspect(other_pid)}"

      :error ->
        :ok
    end

    {:ok, _} =
      NimbleOwnership.get_and_update(@server, self(), @key, fn events ->
        {:ignored, events || []}
      end)

    if not cleanup? do
      :ok = NimbleOwnership.set_owner_to_manual_cleanup(@server, owner_pid)
    end

    :ok
  end

  @doc """
  Cleans up test resources associated with `owner_pid`.

  See the `:cleanup` option in `start_collecting/1` and the corresponding
  example for more information.
  """
  @doc since: "10.2.0"
  @spec cleanup(pid()) :: :ok
  def cleanup(owner_pid) when is_pid(owner_pid) do
    :ok = NimbleOwnership.cleanup_owner(@server, owner_pid)
  end

  @doc """
  Allows `pid_to_allow` to collect events back to the root process via `owner_pid`.

  `owner_pid` must be a PID that is currently collecting events or has been allowed
  to collect events. If that's not the case, this function raises an error.

  `pid_to_allow` can also be a **function** that returns a PID. This is useful when
  you want to allow a registered process that is not yet started to collect events. For example:

      Sentry.Test.allow_sentry_reports(self(), fn -> Process.whereis(:my_process) end)

  """
  @doc since: "10.2.0"
  @spec allow_sentry_reports(pid(), pid() | (-> pid())) :: :ok
  def allow_sentry_reports(owner_pid, pid_to_allow)
      when is_pid(owner_pid) and (is_pid(pid_to_allow) or is_function(pid_to_allow, 0)) do
    case NimbleOwnership.allow(@server, owner_pid, pid_to_allow, @key) do
      :ok ->
        :ok

      {:error, reason} ->
        raise "failed to allow #{inspect(pid_to_allow)} to collect events: #{Exception.message(reason)}"
    end
  end

  @doc """
  Pops all the collected events from the current process.

  This function returns a list of all the events that have been collected from the current
  process and all the processes that were allowed through it. If the current process
  is not collecting events, this function raises an error.

  After this function returns, the current process will still be collecting events, but
  the collected events will be reset to `[]`.

  ## Examples

      iex> Sentry.Test.start_collecting_sentry_reports()
      :ok
      iex> Sentry.capture_message("Oops")
      {:ok, ""}
      iex> [%Sentry.Event{} = event] = Sentry.Test.pop_sentry_reports()
      iex> event.message.formatted
      "Oops"

  """
  @doc since: "10.2.0"
  @spec pop_sentry_reports(pid()) :: [Sentry.Event.t()]
  def pop_sentry_reports(owner_pid \\ self()) when is_pid(owner_pid) do
    result =
      try do
        NimbleOwnership.get_and_update(@server, owner_pid, @key, fn
          nil -> {:not_collecting, []}
          events when is_list(events) -> {events, []}
        end)
      catch
        :exit, {:noproc, _} ->
          raise ArgumentError, "not collecting reported events from #{inspect(owner_pid)}"
      end

    case result do
      {:ok, :not_collecting} ->
        raise ArgumentError, "not collecting reported events from #{inspect(owner_pid)}"

      {:ok, events} ->
        events

      {:error, error} when is_exception(error) ->
        raise ArgumentError, "cannot pop Sentry reports: #{Exception.message(error)}"
    end
  end

  ## Helpers

  defp ensure_ownership_server_started do
    case Supervisor.start_child(Sentry.Supervisor, NimbleOwnership.child_spec(name: @server)) do
      {:ok, pid} ->
        pid

      {:error, {:already_started, pid}} ->
        pid

      {:error, reason} ->
        raise "could not start required processes for Sentry.Test: #{inspect(reason)}"
    end
  end

  defp callers do
    [self()] ++ Process.get(:"$callers", [])
  end
end
