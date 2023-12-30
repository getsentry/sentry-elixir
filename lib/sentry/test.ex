defmodule Sentry.Test do
  @moduledoc """
  Assertions and expectations for testing Sentry reports.
  """

  @server __MODULE__.OwnershipServer

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link([]) do
    case NimbleOwnership.start_link(name: @server) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  TODO
  """
  @spec start_collecting() :: :ok
  def start_collecting do
    parent_pid = self()

    result =
      NimbleOwnership.get_and_update(@server, [], :events, fn
        nil ->
          {:set_owner, parent_pid, :ok, %{collected_events: []}}

        # No-op
        %{owner: ^parent_pid, metadata: metadata} ->
          {:update_metadata, :ok, metadata}

        %{owner: owner_pid} ->
          {:error, {:already_owned, owner_pid}}
      end)

    case result do
      :ok ->
        :ok

      {:error, {:already_owned, owner_pid}} ->
        raise ArgumentError, "already collecting reported events from #{inspect(owner_pid)}"
    end
  end

  @spec allow(pid(), pid()) :: :ok
  def allow(owner_pid, pid_to_allow) do
    case NimbleOwnership.allow(:TODO, owner_pid, pid_to_allow, :events) do
      :ok ->
        :ok

      {:error, reason} ->
        raise ArgumentError,
              "failed to allow #{inspect(pid_to_allow)} to collect events: #{inspect(reason)}"
    end
  end

  @spec pop_reported_events() :: [Sentry.Event.t()]
  def pop_reported_events do
    result =
      NimbleOwnership.get_and_update(:TODO, [self()], :events, fn
        nil ->
          {:error, :not_collecting}

        %{metadata: %{collected_events: events} = metadata} ->
          {:update_metadata, {:ok, events}, %{metadata | collected_events: []}}
      end)

    case result do
      {:error, :not_collecting} ->
        raise ArgumentError, "not collecting reported events"

      {:ok, events} ->
        events
    end
  end
end
