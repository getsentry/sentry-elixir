defmodule Sentry.Transport.RateLimiter do
  @moduledoc false

  # Tracks rate limits per category from Sentry API responses.
  # Uses an ETS table to store expiry timestamps for rate-limited categories.
  # When Sentry returns a 429 response with rate limit headers, this module
  # stores the expiry time per category, allowing other parts of the SDK to
  # check if an event should be dropped before sending.
  #
  # The ETS table stores tuples with these elements:
  #
  #   1. Category (String.t/0 | :global): the category being rate limited.
  #   2. Expiry timestamp (Unix timestamp in seconds): time at which the rate-limit
  #      entry expires and can be pruned).
  #
  # See https://develop.sentry.dev/sdk/expected-features/rate-limiting/

  use GenServer

  @default_sweep_interval_ms 60_000

  defstruct [:table_name]

  ## Public API

  @doc """
  Starts the RateLimiter GenServer.

  ## Options

    * `:name` - The name to register the GenServer under. Defaults to `__MODULE__`.
    * `:table_name` - The name for the ETS table. Defaults to `__MODULE__`.

  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  ## GenServer Callbacks

  @impl true
  def init(opts) do
    table_name = Keyword.get(opts, :table_name, __MODULE__)
    _table = :ets.new(table_name, [:named_table, :public, :set, read_concurrency: true])
    schedule_sweep()
    {:ok, %__MODULE__{table_name: table_name}}
  end

  @impl true
  def handle_info(:sweep, %__MODULE__{table_name: table_name} = state) do
    now = System.system_time(:second)

    # This match spec elects entries where expiry is in the past.
    # Remember, tuples are {category, expiry_time}.
    match_spec = [{{:"$1", :"$2"}, [{:<, :"$2", now}], [true]}]

    :ets.select_delete(table_name, match_spec)

    schedule_sweep()
    {:noreply, state}
  end

  ## Public Functions

  @doc """
  Checks if the given category is currently rate-limited.

  Returns `true` if the category is rate-limited (either specifically or via
  a global rate limit), `false` otherwise.

  ## Options

    * `:table_name` - The ETS table name. Falls back to the `:rate_limiter_table_name`
      value in the process dictionary, then to `__MODULE__`.

  ## Examples

      iex> RateLimiter.rate_limited?("error")
      false

      iex> :ets.insert(RateLimiter, {"error", System.system_time(:second) + 60})
      iex> RateLimiter.rate_limited?("error")
      true

  """
  @spec rate_limited?(String.t(), keyword()) :: boolean()
  def rate_limited?(category, opts \\ []) do
    table_name = get_table_name(opts)
    now = System.system_time(:second)
    rate_limited?(table_name, category, now) or rate_limited?(table_name, :global, now)
  end

  @doc """
  Updates global rate limit from a `Retry-After` header value.

  This is a fallback for when `X-Sentry-Rate-Limits` is not present.
  Stores a global rate limit (`:global` key) that affects all categories.
  The `Retry-After` header is parsed before getting here, so we get a clean
  integer value here.

  ## Options

    * `:table_name` - The ETS table name. Falls back to the `:rate_limiter_table_name`
      value in the process dictionary, then to `__MODULE__`.

  ## Examples

      iex> RateLimiter.update_global_rate_limit(60)
      :ok

  """
  @spec update_global_rate_limit(pos_integer(), keyword()) :: :ok
  def update_global_rate_limit(retry_after_seconds, opts \\ [])
      when is_integer(retry_after_seconds) do
    expiry = System.system_time(:second) + retry_after_seconds
    :ets.insert(get_table_name(opts), {:global, expiry})
    :ok
  end

  @doc """
  Updates rate limits from the `X-Sentry-Rate-Limits` header value.

  Parses the header value and stores expiry timestamps for each category.
  Returns `:ok` regardless of parsing success.

  ## Options

    * `:table_name` - The ETS table name. Falls back to the `:rate_limiter_table_name`
      value in the process dictionary, then to `__MODULE__`.

  ## Examples

      iex> RateLimiter.update_rate_limits("60:error;transaction")
      :ok

  """
  @spec update_rate_limits(String.t(), keyword()) :: :ok
  def update_rate_limits(rate_limits_header, opts \\ []) do
    now = System.system_time(:second)

    rate_limits_header
    |> parse_rate_limits_header()
    |> Enum.map(fn {category, retry_after_seconds} -> {category, now + retry_after_seconds} end)
    |> then(&:ets.insert(get_table_name(opts), &1))
  end

  ## Private Helpers

  # Get the table name with the following hierarchy:
  # 1. Value passed in opts[:table_name]
  # 2. Value from process dictionary (:rate_limiter_table_name)
  # 3. Default module name
  defp get_table_name(opts) do
    case Keyword.fetch(opts, :table_name) do
      {:ok, table_name} -> table_name
      :error -> Process.get(:rate_limiter_table_name, __MODULE__)
    end
  end

  defp rate_limited?(table_name, category, now) do
    case :ets.lookup(table_name, category) do
      [{^category, expiry}] when expiry > now -> true
      _other -> false
    end
  end

  # Parse X-Sentry-Rate-Limits header
  # Format: "60:error;transaction:key, 2700:default:organization"
  # This would mean
  # Returns: [{category, retry_after_seconds}, ...]
  defp parse_rate_limits_header(header_value) do
    header_value
    |> String.split(",")
    |> Enum.flat_map(fn quota_limit -> quota_limit |> String.trim() |> parse_quota_limit() end)
  end

  # Parses a single quota limit, like: "60:error;transaction:key"
  defp parse_quota_limit(quota_limit_str) do
    with [retry_after_str | rest] <- String.split(quota_limit_str, ":", trim: true),
         {retry_after, ""} <- Integer.parse(retry_after_str) do
      rest
      |> parse_categories()
      |> Enum.map(&{&1, retry_after})
    end
  end

  defp parse_categories([categories_str | _rest]) do
    case String.split(categories_str, ";", trim: true) do
      [] -> [:global]
      categories -> categories
    end
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @default_sweep_interval_ms)
  end
end
