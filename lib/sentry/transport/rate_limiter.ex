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
  #   2. Expiry timestamp (Unix timestamp in milliseconds): time at which the rate-limit
  #      entry expires and can be pruned). Milliseconds because the protocol allows
  #      fractional retry delays, which whole seconds cannot represent.
  #
  # See https://develop.sentry.dev/sdk/expected-features/rate-limiting/
  #
  # For testing, we use the trick of determining the name of this GenServer
  # and consequently the ETS table it uses) based on the Mix environment (at compile
  # time, so no impact on performance). If we're in the :test environment, we require
  # that there's a table name for this in the process dictionary. In normal circumstances
  # we use __MODULE__ instead.

  use GenServer

  alias Sentry.LoggerUtils

  @default_sweep_interval_ms 60_000

  defstruct [:table_name]

  ## Public API

  @doc """
  Starts the RateLimiter GenServer.

  ## Options

    * `:name` - The name to register the GenServer under. Defaults to `__MODULE__`.

  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, _table_name = name, name: name)
  end

  ## GenServer Callbacks

  @impl true
  def init(table_name) do
    _table = :ets.new(table_name, [:named_table, :public, :set, read_concurrency: true])
    schedule_sweep()
    {:ok, %__MODULE__{table_name: table_name}}
  end

  @impl true
  def handle_info(:sweep, %__MODULE__{table_name: table_name} = state) do
    now = System.system_time(:millisecond)

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

  ## Examples

      iex> RateLimiter.rate_limited?("error")
      false

      iex> :ets.insert(RateLimiter, {"error", System.system_time(:millisecond) + 60_000})
      iex> RateLimiter.rate_limited?("error")
      true

  """
  @spec rate_limited?(String.t()) :: boolean()
  def rate_limited?(category) when is_binary(category) do
    now = System.system_time(:millisecond)
    rate_limited?(category, now) or rate_limited?(:global, now)
  end

  @spec global_rate_limited?() :: boolean()
  def global_rate_limited? do
    rate_limited?(:global, System.system_time(:millisecond))
  end

  @doc """
  Checks whether sending items of the given data category is currently limited.

  Logs, metrics, and attachments have companion categories (`log_byte`,
  `trace_metric_byte`, and `attachment_item`) that Sentry can limit
  independently of the count category, so a limit on either one must suppress
  sending. Every other category gates on itself alone.

  So an active `log_byte` limit makes this return `true` for `"log_item"`, and
  an active `attachment_item` limit does the same for `"attachment"`, even
  though the corresponding `rate_limited?/1` call on its own is `false`.
  """
  @spec rate_limited_for_category?(String.t()) :: boolean()
  def rate_limited_for_category?("log_item"),
    do: rate_limited?("log_item") or rate_limited?("log_byte")

  def rate_limited_for_category?("trace_metric"),
    do: rate_limited?("trace_metric") or rate_limited?("trace_metric_byte")

  def rate_limited_for_category?("attachment"),
    do: rate_limited?("attachment") or rate_limited?("attachment_item")

  def rate_limited_for_category?(category) when is_binary(category),
    do: rate_limited?(category)

  @doc """
  Updates global rate limit from a `Retry-After` header value.

  This is a fallback for when `X-Sentry-Rate-Limits` is not present.
  Stores a global rate limit (`:global` key) that affects all categories.
  The `Retry-After` header is parsed before getting here, so we get a clean
  integer value here.

  ## Examples

      iex> RateLimiter.update_global_rate_limit(60)
      :ok

  """
  @spec update_global_rate_limit(pos_integer()) :: :ok
  def update_global_rate_limit(retry_after_seconds) when is_integer(retry_after_seconds) do
    now = System.system_time(:millisecond)
    expiry = now + retry_after_seconds * 1000

    store_limits([{:global, expiry}], now)
  end

  @doc """
  Updates rate limits from the `X-Sentry-Rate-Limits` header value.

  Parses the header value and stores expiry timestamps for each category.
  Returns `:ok` regardless of parsing success.

  ## Examples

      iex> RateLimiter.update_rate_limits("60:error;transaction")
      :ok

  """
  @spec update_rate_limits(String.t()) :: :ok
  def update_rate_limits(rate_limits_header) when is_binary(rate_limits_header) do
    now = System.system_time(:millisecond)

    rate_limits_header
    |> parse_rate_limits_header()
    |> Enum.map(fn {category, retry_after_ms} -> {category, now + retry_after_ms} end)
    |> store_limits(now)
  end

  defp store_limits(limits, now) do
    limits
    |> Enum.reduce(%{}, fn {category, expiry}, acc ->
      Map.update(acc, category, expiry, &max(&1, expiry))
    end)
    |> Enum.filter(fn {category, expiry} ->
      store_max_expiry(category, expiry, now) == :started and expiry > now
    end)
    |> log_new_limits(now)
  end

  defp log_new_limits([], _now), do: :ok

  defp log_new_limits(limits, now) do
    LoggerUtils.log(fn ->
      [
        "Sentry is rate-limiting ",
        Enum.map_join(limits, ", ", &format_limit(&1, now)),
        ". Data is dropped locally until the limit expires."
      ]
    end)
  end

  defp format_limit({category, expiry}, now) do
    "#{format_category(category)} for #{format_duration(expiry - now)} (until #{format_expiry(expiry)})"
  end

  defp format_category(:global), do: "all data categories"
  defp format_category(category), do: ~s(the "#{category}" data category)

  defp format_duration(duration_ms) when duration_ms >= 1000, do: "#{div(duration_ms, 1000)}s"
  defp format_duration(duration_ms), do: "#{duration_ms}ms"

  defp format_expiry(expiry) do
    expiry
    |> DateTime.from_unix!(:millisecond)
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  # Rate limits may only ever be extended: a response carrying a shorter delay
  # than the one already in flight must not let the SDK resume sending early.
  #
  # Senders handle responses concurrently, so this compares and swaps rather than
  # reading and then writing: two responses racing on the same category would
  # otherwise both read the old expiry and let the shorter one land last.
  # The write also reports whether it opened a new window (`:started`) or merely
  # pushed an active one further out (`:extended`), so that callers announcing a
  # limit do so exactly once even when responses are handled concurrently.
  defp store_max_expiry(category, expiry, now) do
    table = name()

    if :ets.insert_new(table, {category, expiry}) do
      :started
    else
      replace_lapsed_expiry(table, category, expiry, now)
    end
  end

  defp replace_lapsed_expiry(table, category, expiry, now) do
    match_spec = [
      {{category, :"$1"}, [{:<, :"$1", now}, {:<, :"$1", expiry}],
       [{{{:const, category}, {:const, expiry}}}]}
    ]

    case :ets.select_replace(table, match_spec) do
      1 -> :started
      0 -> replace_shorter_expiry(table, category, expiry, now)
    end
  end

  defp replace_shorter_expiry(table, category, expiry, now) do
    match_spec = [
      {{category, :"$1"}, [{:<, :"$1", expiry}], [{{{:const, category}, {:const, expiry}}}]}
    ]

    case :ets.select_replace(table, match_spec) do
      1 ->
        :extended

      0 ->
        # Either the stored expiry is already the longer one, or the sweeper
        # pruned the entry between the two calls and it has to be re-inserted.
        if :ets.member(table, category),
          do: :extended,
          else: store_max_expiry(category, expiry, now)
    end
  end

  defp rate_limited?(category, now) do
    case :ets.lookup(name(), category) do
      [{^category, expiry}] when expiry > now -> true
      _other -> false
    end
  end

  # Parse X-Sentry-Rate-Limits header
  # Format: "60:error;transaction:key, 2700:default:organization"
  # Returns: [{category, retry_after_ms}, ...]
  defp parse_rate_limits_header(header_value) do
    header_value
    |> String.split(",")
    |> Enum.flat_map(fn quota_limit -> quota_limit |> String.trim() |> parse_quota_limit() end)
  end

  # Parses a single quota limit, like: "60:error;transaction:key"
  defp parse_quota_limit(quota_limit_str) do
    with [retry_after_str | rest] <- String.split(quota_limit_str, ":"),
         {:ok, retry_after_ms} <- parse_retry_after_ms(retry_after_str) do
      rest
      |> parse_categories()
      |> Enum.map(&{&1, retry_after_ms})
    else
      _other -> []
    end
  end

  # The protocol allows the retry delay to be an integer or a floating-point
  # number of seconds. Fractions round up so that the SDK never resumes sending
  # before the server said it could.
  defp parse_retry_after_ms(retry_after_str) do
    case Float.parse(retry_after_str) do
      {seconds, ""} when seconds >= 0 -> {:ok, ceil(seconds * 1000)}
      _other -> :error
    end
  end

  defp parse_categories([categories_str | _rest]) do
    case String.split(categories_str, ";", trim: true) do
      [] -> [:global]
      categories -> categories
    end
  end

  defp parse_categories([]) do
    [:global]
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @default_sweep_interval_ms)
  end

  if Mix.env() == :test do
    defp name, do: Process.get(:rate_limiter_table_name, __MODULE__)
  else
    defp name, do: __MODULE__
  end
end
