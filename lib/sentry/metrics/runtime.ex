defmodule Sentry.Metrics.Runtime do
  @moduledoc false

  use GenServer

  alias Sentry.LoggerUtils
  alias Sentry.Metrics

  @memory_gauges [:total, :processes, :binary, :ets, :atom]

  @origin "auto.elixir.runtime_metrics"

  # The 30s default interval and this floor mirror DEFAULT_INTERVAL_MS and
  # MIN_COLLECTION_INTERVAL_MS in the JavaScript SDKs' runtime metrics integrations, so
  # collectors behave consistently across Sentry SDKs.
  @min_interval 1_000

  defstruct [:interval, :attributes, :memory_available?]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    interval = normalize_interval(Keyword.fetch!(opts, :interval))

    attributes =
      Map.merge(
        %{"sentry.origin" => @origin},
        version_attributes(Keyword.get(opts, :version_attributes, false))
      )

    schedule_tick(interval)

    {:ok,
     %__MODULE__{
       interval: interval,
       attributes: attributes,
       memory_available?: memory_available?()
     }}
  end

  @impl true
  def handle_info(:tick, %__MODULE__{} = state) do
    collect_and_emit(state)
    schedule_tick(state.interval)
    {:noreply, state}
  end

  defp collect_and_emit(%__MODULE__{} = state) do
    if state.memory_available? do
      memory = :erlang.memory()

      Enum.each(@memory_gauges, fn key ->
        gauge(state, "elixir.runtime.mem.#{key}", Keyword.fetch!(memory, key), unit: "byte")
      end)
    end

    :ok
  end

  # `:erlang.memory/0` raises `notsup` when an `erts_alloc` allocator was disabled at boot.
  # Allocator configuration is fixed for the lifetime of the VM, so this is probed once instead
  # of guarding every tick, and reported once so the missing gauges have a stated reason.
  defp memory_available? do
    _ = :erlang.memory()
    true
  rescue
    ErlangError ->
      LoggerUtils.warning(
        "[Sentry] runtime memory metrics are unavailable because this node was started with " <>
          "an erts_alloc allocator disabled; other runtime metrics are unaffected"
      )

      false
  end

  defp gauge(%__MODULE__{} = state, name, value, opts) do
    Metrics.gauge(name, value, Keyword.put(opts, :attributes, state.attributes))
  end

  defp normalize_interval(interval) when is_integer(interval) and interval >= @min_interval do
    interval
  end

  defp normalize_interval(interval) do
    LoggerUtils.warning(
      "[Sentry] runtime metrics collection interval of #{inspect(interval)}ms is below the " <>
        "supported minimum, falling back to #{@min_interval}ms"
    )

    @min_interval
  end

  defp version_attributes(false), do: %{}

  defp version_attributes(true) do
    %{
      elixir_version: System.version(),
      otp_release: List.to_string(:erlang.system_info(:otp_release))
    }
  end

  defp schedule_tick(interval), do: Process.send_after(self(), :tick, interval)
end
