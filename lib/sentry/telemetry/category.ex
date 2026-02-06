defmodule Sentry.Telemetry.Category do
  @moduledoc """
  Defines telemetry categories for the Sentry SDK with their priorities and default configurations.

  The TelemetryProcessor uses categories to classify different types of telemetry data
  and prioritize their sending based on a weighted round-robin scheduler.

  Currently, only the `:log` category is managed by the TelemetryProcessor.
  Other categories (errors, transactions, check-ins) will be added in future versions.

  ## Categories

    * `:log` - Log entries (low priority)

  ## Priorities and Weights

    * `:low` - weight 2 (logs)

  """
  @moduledoc since: "12.0.0"

  @typedoc "Telemetry category types."
  @type t :: :log

  @typedoc "Priority levels for categories."
  @type priority :: :low

  @typedoc "Buffer configuration for a category."
  @type config :: %{
          capacity: pos_integer(),
          batch_size: pos_integer(),
          timeout: pos_integer() | nil
        }

  @priorities [:low]
  @categories [:log]

  @weights %{
    low: 2
  }

  @default_configs %{
    log: %{capacity: 1000, batch_size: 100, timeout: 5000}
  }

  @doc """
  Returns the priority level for a given category.

  ## Examples

      iex> Sentry.Telemetry.Category.priority(:log)
      :low

  """
  @spec priority(t()) :: priority()
  def priority(:log), do: :low

  @doc """
  Returns the weight for a given priority level.

  Weights determine how many slots each priority gets in the round-robin cycle.

  ## Examples

      iex> Sentry.Telemetry.Category.weight(:low)
      2

  """
  @spec weight(priority()) :: pos_integer()
  def weight(priority) when priority in @priorities do
    Map.fetch!(@weights, priority)
  end

  @doc """
  Returns the default buffer configuration for a given category.

  ## Configuration keys

    * `:capacity` - Maximum items the buffer can hold
    * `:batch_size` - Number of items to send per batch
    * `:timeout` - Flush timeout in milliseconds (nil for immediate)

  ## Examples

      iex> Sentry.Telemetry.Category.default_config(:log)
      %{capacity: 1000, batch_size: 100, timeout: 5000}

  """
  @spec default_config(t()) :: config()
  def default_config(category) when category in @categories do
    Map.fetch!(@default_configs, category)
  end

  @doc """
  Returns all telemetry categories.

  ## Examples

      iex> Sentry.Telemetry.Category.all()
      [:log]

  """
  @spec all() :: [t()]
  def all, do: @categories

  @doc """
  Returns all priority levels in descending order (highest to lowest).

  ## Examples

      iex> Sentry.Telemetry.Category.priorities()
      [:low]

  """
  @spec priorities() :: [priority()]
  def priorities, do: @priorities
end
