defmodule Sentry.Telemetry.Category do
  @moduledoc """
  Defines telemetry categories for the Sentry SDK with their priorities and default configurations.

  The TelemetryProcessor uses categories to classify different types of telemetry data
  and prioritize their sending based on a weighted round-robin scheduler.

  ## Categories

    * `:error` - Error events (critical priority)
    * `:check_in` - Cron check-ins (high priority)
    * `:transaction` - Performance transactions (medium priority)
    * `:log` - Log entries (low priority)

  ## Priorities and Weights

    * `:critical` - weight 5 (errors)
    * `:high` - weight 4 (check-ins)
    * `:medium` - weight 3 (transactions)
    * `:low` - weight 2 (logs)

  """
  @moduledoc since: "12.0.0"

  @typedoc "Telemetry category types."
  @type t :: :error | :check_in | :transaction | :log

  @typedoc "Priority levels for categories."
  @type priority :: :critical | :high | :medium | :low

  @typedoc "Buffer configuration for a category."
  @type config :: %{
          capacity: pos_integer(),
          batch_size: pos_integer(),
          timeout: pos_integer() | nil
        }

  @priorities [:critical, :high, :medium, :low]
  @categories [:error, :check_in, :transaction, :log]

  @weights %{
    critical: 5,
    high: 4,
    medium: 3,
    low: 2
  }

  @default_configs %{
    error: %{capacity: 100, batch_size: 1, timeout: nil},
    check_in: %{capacity: 100, batch_size: 1, timeout: nil},
    transaction: %{capacity: 1000, batch_size: 1, timeout: nil},
    log: %{capacity: 1000, batch_size: 100, timeout: 5000}
  }

  @doc """
  Returns the priority level for a given category.

  ## Examples

      iex> Sentry.Telemetry.Category.priority(:error)
      :critical

      iex> Sentry.Telemetry.Category.priority(:check_in)
      :high

      iex> Sentry.Telemetry.Category.priority(:transaction)
      :medium

      iex> Sentry.Telemetry.Category.priority(:log)
      :low

  """
  @spec priority(t()) :: priority()
  def priority(:error), do: :critical
  def priority(:check_in), do: :high
  def priority(:transaction), do: :medium
  def priority(:log), do: :low

  @doc """
  Returns the weight for a given priority level.

  Weights determine how many slots each priority gets in the round-robin cycle.

  ## Examples

      iex> Sentry.Telemetry.Category.weight(:high)
      4

      iex> Sentry.Telemetry.Category.weight(:medium)
      3

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

      iex> Sentry.Telemetry.Category.default_config(:error)
      %{capacity: 100, batch_size: 1, timeout: nil}

      iex> Sentry.Telemetry.Category.default_config(:check_in)
      %{capacity: 100, batch_size: 1, timeout: nil}

      iex> Sentry.Telemetry.Category.default_config(:transaction)
      %{capacity: 1000, batch_size: 1, timeout: nil}

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
      [:error, :check_in, :transaction, :log]

  """
  @spec all() :: [t()]
  def all, do: @categories

  @doc """
  Returns all priority levels in descending order (highest to lowest).

  ## Examples

      iex> Sentry.Telemetry.Category.priorities()
      [:critical, :high, :medium, :low]

  """
  @spec priorities() :: [priority()]
  def priorities, do: @priorities

  @doc """
  Returns the Sentry data category string for a given telemetry category.

  These strings are used in client reports and rate limiting.

  ## Examples

      iex> Sentry.Telemetry.Category.data_category(:error)
      "error"

      iex> Sentry.Telemetry.Category.data_category(:check_in)
      "monitor"

      iex> Sentry.Telemetry.Category.data_category(:log)
      "log_item"

  """
  @spec data_category(t()) :: String.t()
  def data_category(:error), do: "error"
  def data_category(:check_in), do: "monitor"
  def data_category(:transaction), do: "transaction"
  def data_category(:log), do: "log_item"
end
