defmodule Sentry.Test do
  @moduledoc """
  Utilities for testing Sentry reports.

  ## Usage

  This module is based on **collecting** reported events and then retrieving
  them to perform assertions. You can start collecting events from a process
  by calling `start_collecting_sentry_reports/0`. Then, you can use Sentry
  as normal and report events (through functions such as `Sentry.capture_message/1`
  or `Sentry.capture_exception/1`). Finally, you can retrieve the collected events
  by calling `pop_sentry_reports/0`.

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

        :error ->
          :not_collecting
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

  """
  @doc since: "10.2.0"
  @spec start_collecting_sentry_reports(map()) :: :ok
  def start_collecting_sentry_reports(_context \\ %{}) do
    # Make sure the ownership server is started (this is idempotent).
    ensure_ownership_server_started()

    case NimbleOwnership.fetch_owner(@server, callers(), @key) do
      # No-op
      {tag, owner_pid} when tag in [:ok, :shared_owner] and owner_pid == self() ->
        :ok

      {:shared_owner, _pid} ->
        raise ArgumentError,
              "Sentry.Test is in global mode and is already collecting reported events"

      {:ok, another_pid} ->
        raise ArgumentError, "already collecting reported events from #{inspect(another_pid)}"

      :error ->
        :ok
    end

    {:ok, _} =
      NimbleOwnership.get_and_update(@server, self(), @key, fn events ->
        {:ignored, events || []}
      end)

    :ok
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
  @spec pop_sentry_reports() :: [Sentry.Event.t()]
  def pop_sentry_reports do
    result =
      NimbleOwnership.get_and_update(@server, self(), @key, fn
        nil -> {:not_collecting, []}
        events when is_list(events) -> {events, []}
      end)

    case result do
      {:ok, :not_collecting} ->
        raise ArgumentError, "not collecting reported events from #{inspect(self())}"

      {:ok, events} ->
        events

      {:error, error} when is_exception(error) ->
        raise ArgumentError, "cannot pop Sentry reports: #{Exception.message(error)}"
    end
  end

  ## Helpers

  defp ensure_ownership_server_started do
    case NimbleOwnership.start_link(name: @server) do
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
