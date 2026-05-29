defmodule Sentry.Scrubber do
  @moduledoc """
  Shared, framework-agnostic helpers for scrubbing sensitive data before it is
  sent to Sentry.

  *Available since v13.1.0.*

  This module owns the default sensitive key lists, the placeholder used in
  place of redacted values, the credit-card detection heuristic, and the
  recursive map/list traversal used by the rest of the SDK to redact values.
  Integrations such as `Sentry.PlugContext`, `Sentry.PlugCapture`, and
  `Sentry.LiveViewHook` delegate to the functions exposed here so that
  scrubbing rules live in a single place.

  ## Defaults

  The default sensitive *parameter* keys (used for body params, query strings,
  and arbitrary maps) are:

  #{Enum.map_join(["password", "passwd", "secret"], "\n", &"  * `\"#{&1}\"`")}

  The default sensitive *header* keys are:

  #{Enum.map_join(["authorization", "authentication", "cookie"], "\n", &"  * `\"#{&1}\"`")}

  Values matching a credit-card-like pattern (13–16 digits, optionally
  separated by spaces or dashes) are also replaced with the placeholder.

  ## Custom scrubbing

  The map/query/header functions accept an optional `:keys` option that
  overrides the default list of sensitive keys. This makes it possible to
  compose custom scrubbers on top of the defaults:

      def scrub(map) do
        map
        |> Sentry.Scrubber.scrub(keys: ["password", "api_key"])
        |> Map.drop(["internal_notes"])
      end

  ## Scrubbing a `%Plug.Conn{}`

  Conn scrubbing is configured per process rather than per call. Register the
  per-field scrubbers once with `put_conn_scrubber/1` (typically from
  `Sentry.PlugContext.call/2`), then `scrub/1` redacts a conn's params,
  headers, and cookies using that registration, and `scrub_request_url/1`
  returns the conn's request URL through the registered `:url_scrubber`. Any
  field left unregistered falls back to the default behavior described on
  `scrub/2`'s `scrub(field, value)` clause.
  """

  @moduledoc since: "13.1.0"

  @default_scrubbed_param_keys ["password", "passwd", "secret"]
  @default_scrubbed_header_keys ["authorization", "authentication", "cookie"]
  @scrubbed_value "*********"
  @scrubber_pdict_key {__MODULE__, :scrubber}
  @scrubber_names [:body_scrubber, :header_scrubber, :cookie_scrubber, :url_scrubber]

  @typedoc """
  A resolved set of per-field scrubbers for a `%Plug.Conn{}`.

  Each field holds a 1-arity function that takes the conn and returns the
  scrubbed value for the corresponding field. Built by `put_conn_scrubber/1`
  from `t:conn_scrubber_opts/0` and stored in the process dictionary.
  """
  @type t :: %__MODULE__{
          body_scrubber: (Plug.Conn.t() -> term()),
          header_scrubber: (Plug.Conn.t() -> term()),
          cookie_scrubber: (Plug.Conn.t() -> term()),
          url_scrubber: (Plug.Conn.t() -> String.t())
        }

  @enforce_keys @scrubber_names
  defstruct @scrubber_names

  @doc false
  @spec scrubber_names() :: [atom()]
  def scrubber_names, do: @scrubber_names

  @typedoc """
  Options accepted by the scrubbing functions in this module.
  """
  @type option :: {:keys, [String.t()]}

  @typedoc """
  A per-field scrubber identifying how to redact a particular `%Plug.Conn{}`
  field.

    * a 1-arity function — invoked as `fun.(conn)`
    * `{module, function}` — invoked as `apply(module, function, [conn])`
    * `nil` — disables the scrubber; the field is replaced with `%{}`
  """
  @type field_scrubber ::
          (Plug.Conn.t() -> term()) | {module(), atom()} | nil

  @typedoc """
  Options accepted by `put_conn_scrubber/1`.

  Each key, when omitted, falls back to the corresponding `default_*_scrubber/1`.
  """
  @type conn_scrubber_opts :: [
          body_scrubber: field_scrubber(),
          header_scrubber: field_scrubber(),
          cookie_scrubber: field_scrubber(),
          url_scrubber: field_scrubber()
        ]

  @doc """
  The placeholder string used to replace scrubbed values.
  """
  @doc since: "13.1.0"
  @spec scrubbed_value() :: String.t()
  def scrubbed_value, do: @scrubbed_value

  @doc """
  Returns the default list of sensitive parameter keys.
  """
  @doc since: "13.1.0"
  @spec default_param_keys() :: [String.t()]
  def default_param_keys, do: @default_scrubbed_param_keys

  @doc """
  Returns the default list of sensitive header keys.
  """
  @doc since: "13.1.0"
  @spec default_header_keys() :: [String.t()]
  def default_header_keys, do: @default_scrubbed_header_keys

  @doc """
  Drops sensitive keys from a flat map.

  This is the strategy used for HTTP headers, where the sensitive value should
  not appear in the payload at all.

  ## Options

    * `:keys` - the list of sensitive keys to drop. Defaults to
      `default_header_keys/0`.
  """
  @doc since: "13.1.0"
  @spec drop_keys(map(), [option()]) :: map()
  def drop_keys(map, opts \\ []) when is_map(map) do
    keys = Keyword.get(opts, :keys, @default_scrubbed_header_keys)
    Map.drop(map, keys)
  end

  @doc """
  Scrubs the query string portion of a URL, replacing the value of any
  sensitive query parameter with the placeholder. URLs without a query string
  are returned unchanged.

  ## Options

  See `scrub/2`.
  """
  @doc since: "13.1.0"
  @spec scrub_url(String.t(), [option()]) :: String.t()
  def scrub_url(url, opts \\ []) when is_binary(url) do
    case URI.parse(url) do
      %URI{query: nil} ->
        url

      %URI{query: ""} ->
        url

      %URI{query: query} = uri ->
        URI.to_string(%{uri | query: scrub_query_string(query, opts)})
    end
  end

  @doc """
  Scrubs an `application/x-www-form-urlencoded` query string, replacing the
  value of any sensitive parameter with the placeholder.

  ## Options

  See `scrub/2`.
  """
  @doc since: "13.1.0"
  @spec scrub_query_string(String.t(), [option()]) :: String.t()
  def scrub_query_string(query, opts \\ []) when is_binary(query) do
    keys = Keyword.get(opts, :keys, @default_scrubbed_param_keys)

    query
    |> URI.query_decoder()
    |> Enum.map(fn {key, value} ->
      cond do
        key in keys -> {key, @scrubbed_value}
        is_binary(value) and value =~ credit_card_regex() -> {key, @scrubbed_value}
        true -> {key, value}
      end
    end)
    |> URI.encode_query()
  end

  @doc """
  Registers the current process's per-field scrubbers for `%Plug.Conn{}`.

  Accepts the same `:body_scrubber`, `:header_scrubber`, `:cookie_scrubber`,
  and `:url_scrubber` keys that `Sentry.PlugContext` takes as plug options,
  resolves each missing key to its corresponding `default_*_scrubber/1`, and
  stores the resolved scrubbers in the process dictionary.

  The registration lives for the lifetime of the calling process — typically
  the request process when registered from `Sentry.PlugContext.call/2`. Used
  by other parts of the SDK (notably `Sentry.PlugCapture`) so all conn
  scrubbing honors the same configuration the user passed to
  `plug Sentry.PlugContext`.

  Returns `:ok`.
  """
  @doc since: "13.1.1"
  @spec put_conn_scrubber(conn_scrubber_opts()) :: :ok
  def put_conn_scrubber(opts) when is_list(opts) do
    Process.put(@scrubber_pdict_key, resolve_scrubbers(opts))
    :ok
  end

  defp resolve_scrubbers(opts) do
    %__MODULE__{
      body_scrubber: resolve_scrubber(opts, :body_scrubber, :body),
      header_scrubber: resolve_scrubber(opts, :header_scrubber, :headers),
      cookie_scrubber: resolve_scrubber(opts, :cookie_scrubber, :cookies),
      url_scrubber: resolve_scrubber(opts, :url_scrubber, :url)
    }
  end

  defp resolve_scrubber(opts, opt_name, field) do
    case Keyword.fetch(opts, opt_name) do
      :error ->
        fn conn -> scrub(field, conn) end

      {:ok, nil} when field == :url ->
        fn conn -> scrub(:url, conn) end

      {:ok, nil} ->
        fn _conn -> %{} end

      {:ok, {m, f, args}} when is_atom(m) and is_atom(f) and is_list(args) ->
        fn conn -> apply(m, f, [conn | args]) end

      {:ok, {m, f}} when is_atom(m) and is_atom(f) ->
        fn conn -> apply(m, f, [conn]) end

      {:ok, fun} when is_function(fun, 1) ->
        fun
    end
  end

  @spec scrubber() :: t()
  defp scrubber do
    case Process.get(@scrubber_pdict_key) do
      nil ->
        defaults = resolve_scrubbers([])
        Process.put(@scrubber_pdict_key, defaults)
        defaults

      %__MODULE__{} = scrubbers ->
        scrubbers
    end
  end

  @doc """
  Scrubs a `%Plug.Conn{}` or a plain map.

  Given a `%Plug.Conn{}`, scrubs it using the current process's registered
  scrubbers. When `put_conn_scrubber/1` has been called for this process,
  applies the resolved body, header, and cookie scrubbers to the corresponding
  conn fields. Otherwise falls back to `scrub/2` for each field.

  Given a plain map, recursively scrubs it with the default sensitive keys —
  equivalent to `scrub(map, [])`. See `scrub/2`.
  """
  @doc since: "13.1.1"
  @spec scrub(Plug.Conn.t()) :: Plug.Conn.t()
  @spec scrub(map()) :: map()

  def scrub(conn) when is_struct(conn, Plug.Conn) do
    %{
      conn
      | cookies: scrubber().cookie_scrubber.(conn),
        req_headers: headers_to_list(scrubber().header_scrubber.(conn)),
        params: scrubber().body_scrubber.(conn)
    }
  end

  def scrub(map) when is_map(map) and not is_struct(map), do: scrub(map, [])

  @doc """
  Scrubs a value, dispatching on the first argument.

  ## Scrubbing a map or list — `scrub(map, opts)` / `scrub(list, opts)`

  Recursively scrubs a map. Any value whose key is in the configured sensitive
  key list is replaced with the placeholder. Values matching the credit-card
  pattern are also replaced. Nested maps, structs, and lists are scrubbed
  recursively. A list given as the top-level value is scrubbed element-wise
  using the same rules.

  Accepts the same `:keys` option as the other scrubbing functions:

    * `:keys` - the list of sensitive keys to redact. Defaults to
      `default_param_keys/0`.

  ## Default scrubbing for a `%Plug.Conn{}` field — `scrub(field, conn)`

  Extracts the relevant field from the `conn` itself and applies the SDK's
  default redaction for it:

    * `:body` — scrubs `conn.params` via `scrub/2`; non-map params (such as
      `%Plug.Conn.Unfetched{}`) pass through unchanged.
    * `:headers` — drops sensitive `conn.req_headers` case-insensitively,
      preserving the list-of-tuples shape.
    * `:cookies` — drops *all* cookies, returning `%{}`.
    * `:url` — returns the conn's request URL unchanged.

  Used by `scrub/1` and `scrub_request_url/1` for fields the user has not
  overridden via `put_conn_scrubber/1`, and available for custom scrubbers
  that want to compose the default behavior:

      defmodule MyScrubber do
        def scrub_params(conn) do
          Sentry.Scrubber.scrub(:body, conn)
          |> Map.drop(["my_secret_field"])
        end
      end
  """
  @doc since: "13.1.0"
  @spec scrub(map(), [option()]) :: map()
  @spec scrub(list(), [option()]) :: list()
  @spec scrub(:body | :headers | :cookies | :url, Plug.Conn.t()) :: term()
  def scrub(value, opts \\ [])

  def scrub(map, opts) when is_map(map) and not is_struct(map) and is_list(opts) do
    keys = Keyword.get(opts, :keys, @default_scrubbed_param_keys)
    Map.new(map, fn {key, value} -> {key, scrub_value(key, value, keys)} end)
  end

  def scrub(list, opts) when is_list(list) do
    Enum.map(list, fn value ->
      cond do
        is_struct(value) -> value |> Map.from_struct() |> scrub(opts)
        is_map(value) or is_list(value) -> scrub(value, opts)
        true -> value
      end
    end)
  end

  def scrub(:body, conn) when is_struct(conn, Plug.Conn) do
    if is_map(conn.params) and not is_struct(conn.params) do
      scrub(conn.params)
    else
      conn.params
    end
  end

  def scrub(:headers, conn) when is_struct(conn, Plug.Conn),
    do: drop_sensitive_req_headers(conn.req_headers)

  def scrub(:cookies, conn) when is_struct(conn, Plug.Conn), do: %{}
  def scrub(:url, conn) when is_struct(conn, Plug.Conn), do: Plug.Conn.request_url(conn)

  @spec scrub_request_url(Plug.Conn.t()) :: String.t()
  def scrub_request_url(conn) when is_struct(conn, Plug.Conn), do: scrubber().url_scrubber.(conn)

  defp headers_to_list(headers) when is_map(headers), do: Map.to_list(headers)
  defp headers_to_list(headers) when is_list(headers), do: headers

  defp drop_sensitive_req_headers(headers) do
    Enum.reject(headers, fn
      {name, _value} when is_binary(name) ->
        String.downcase(name) in @default_scrubbed_header_keys

      _ ->
        false
    end)
  end

  defp scrub_value(key, value, keys) do
    cond do
      key in keys -> @scrubbed_value
      is_binary(value) and value =~ credit_card_regex() -> @scrubbed_value
      is_struct(value) -> value |> Map.from_struct() |> scrub(keys: keys)
      is_map(value) or is_list(value) -> scrub(value, keys: keys)
      true -> value
    end
  end

  defp credit_card_regex, do: ~r/^(?:\d[ -]*?){13,16}$/
end
