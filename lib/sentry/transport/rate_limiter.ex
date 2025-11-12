defmodule Sentry.Transport.RateLimiter do
  @moduledoc false
  # Tracks rate limits per category from Sentry API responses.
  # Uses an ETS table to store expiry timestamps for rate-limited categories.
  # When Sentry returns a 429 response with rate limit headers, this module
  # stores the expiry time per category, allowing other parts of the SDK to
  # check if an event should be dropped before sending.
  #
  # See https://develop.sentry.dev/sdk/expected-features/rate-limiting/

  use GenServer

  @table __MODULE__
  @sweep_interval_ms 60_000

  ## Public API

  @doc """
  Starts the RateLimiter GenServer.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, nil, name: Keyword.get(opts, :name, __MODULE__))
  end

  ## GenServer Callbacks

  @impl true
  def init(nil) do
    _table = :ets.new(@table, [:named_table, :public, :set])
    schedule_sweep()
    {:ok, :no_state}
  end

  @impl true
  def handle_info(:sweep, state) do
    now = System.system_time(:second)

    # Match spec: select entries where expiry (position 2) < now
    match_spec = [{{:"$1", :"$2"}, [{:<, :"$2", now}], [true]}]

    :ets.select_delete(@table, match_spec)

    schedule_sweep()
    {:noreply, state}
  end

  ## Public Functions

  @doc """
  Checks if the given category is currently rate-limited.

  Returns `true` if the category is rate-limited (either specifically or via
  a global rate limit), `false` otherwise.

  ## Examples

      iex> RateLimiter.rate_limited?("error")
      false

      iex> :ets.insert(RateLimiter, {"error", System.system_time(:second) + 60})
      iex> RateLimiter.rate_limited?("error")
      true

  """
  @spec rate_limited?(String.t()) :: boolean()
  def rate_limited?(category) do
    now = System.system_time(:second)
    check_rate_limited(category, now) or check_rate_limited(:global, now)
  end

  @doc """
  Updates global rate limit from a Retry-After header value.

  This is a fallback for when X-Sentry-Rate-Limits is not present.
  Stores a global rate limit (:global key) that affects all categories.

  ## Examples

      iex> RateLimiter.update_global_rate_limit(60)
      :ok

  """
  @spec update_global_rate_limit(pos_integer()) :: :ok
  def update_global_rate_limit(retry_after_seconds) when is_integer(retry_after_seconds) do
    now = System.system_time(:second)
    expiry = now + retry_after_seconds
    :ets.insert(@table, {:global, expiry})
    :ok
  end

  @doc """
  Updates rate limits from the X-Sentry-Rate-Limits header.

  Parses the header value and stores expiry timestamps for each category.
  Returns `:ok` regardless of parsing success.

  ## Examples

      iex> RateLimiter.update_rate_limits("60:error;transaction")
      :ok

  """
  @spec update_rate_limits(String.t() | nil) :: :ok
  def update_rate_limits(nil), do: :ok

  def update_rate_limits(rate_limits_header) when is_binary(rate_limits_header) do
    now = System.system_time(:second)
    rate_limits = parse_rate_limits_header(rate_limits_header)

    Enum.each(rate_limits, fn {category, retry_after_seconds} ->
      expiry = now + retry_after_seconds
      :ets.insert(@table, {category, expiry})
    end)

    :ok
  end

  ## Private Helpers

  @spec check_rate_limited(String.t() | :global, integer()) :: boolean()
  defp check_rate_limited(category, time) do
    case :ets.lookup(@table, category) do
      [{^category, expiry}] when expiry > time -> true
      _ -> false
    end
  end

  # Parse X-Sentry-Rate-Limits header
  # Format: "60:error;transaction:key, 2700:default:organization"
  # Returns: [{category, retry_after_seconds}, ...]
  @spec parse_rate_limits_header(String.t()) :: [{String.t() | :global, integer()}]
  defp parse_rate_limits_header(header_value) do
    header_value
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.flat_map(&parse_quota_limit/1)
  end

  @spec parse_quota_limit(String.t()) :: [{String.t() | :global, integer()}]
  defp parse_quota_limit(quota_limit_str) do
    {retry_after_str, rest} = quota_limit_str |> String.split(":") |> List.pop_at(0)

    case parse_retry_after(retry_after_str) do
      {:ok, retry_after} -> parse_categories(rest, retry_after)
      :error -> []
    end
  end

  @spec parse_retry_after(String.t() | nil) :: {:ok, integer()} | :error
  defp parse_retry_after(nil), do: :error

  defp parse_retry_after(retry_after_str) do
    case Integer.parse(retry_after_str) do
      {retry_after, ""} -> {:ok, retry_after}
      _ -> :error
    end
  end

  @spec parse_categories([String.t()], integer()) :: [{String.t() | :global, integer()}]
  defp parse_categories([categories_str | _rest], retry_after) do
    case String.split(categories_str, ";") do
      [""] -> [{:global, retry_after}]
      categories -> Enum.map(categories, fn cat -> {cat, retry_after} end)
    end
  end

  defp parse_categories(_, _), do: []

  @spec schedule_sweep() :: reference()
  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval_ms)
  end
end
