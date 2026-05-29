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

  All public functions accept an optional `:keys` option that overrides the
  default list of sensitive keys. This makes it possible to compose custom
  scrubbers on top of the defaults:

      def scrub(map) do
        map
        |> Sentry.Scrubber.scrub_map(keys: ["password", "api_key"])
        |> Map.drop(["internal_notes"])
      end
  """

  @moduledoc since: "13.1.0"

  @default_scrubbed_param_keys ["password", "passwd", "secret"]
  @default_scrubbed_header_keys ["authorization", "authentication", "cookie"]
  @scrubbed_value "*********"
  @scrubber_pdict_key {__MODULE__, :scrubber}
  @scrubber_names [:body_scrubber, :header_scrubber, :cookie_scrubber, :url_scrubber]

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
  Recursively scrubs a map.

  Any value whose key is in the configured sensitive key list is replaced with
  the placeholder. Values matching the credit-card pattern are also replaced.
  Nested maps, structs, and lists are scrubbed recursively.

  ## Options

    * `:keys` - the list of sensitive keys to redact. Defaults to
      `default_param_keys/0`.
  """
  @doc since: "13.1.0"
  @spec scrub_map(map(), [option()]) :: map()
  def scrub_map(map, opts \\ []) when is_map(map) do
    keys = Keyword.get(opts, :keys, @default_scrubbed_param_keys)
    do_scrub_map(map, keys)
  end

  @doc """
  Recursively scrubs a list, applying the same rules as `scrub_map/2` to any
  maps it contains.

  ## Options

  See `scrub_map/2`.
  """
  @doc since: "13.1.0"
  @spec scrub_list(list(), [option()]) :: list()
  def scrub_list(list, opts \\ []) when is_list(list) do
    keys = Keyword.get(opts, :keys, @default_scrubbed_param_keys)
    do_scrub_list(list, keys)
  end

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

  See `scrub_map/2`.
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

  See `scrub_map/2`.
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
    %{
      body_scrubber: resolve_scrubber(opts, :body_scrubber, :body, & &1.params),
      header_scrubber: resolve_scrubber(opts, :header_scrubber, :headers, & &1.req_headers),
      cookie_scrubber: resolve_scrubber(opts, :cookie_scrubber, :cookies, & &1.cookies),
      url_scrubber:
        resolve_scrubber(opts, :url_scrubber, :url, fn conn -> Plug.Conn.request_url(conn) end)
    }
  end

  defp resolve_scrubber(opts, opt_name, field, extract) do
    case Keyword.fetch(opts, opt_name) do
      :error ->
        fn conn -> scrub(field, extract.(conn)) end

      {:ok, nil} when field == :url ->
        fn conn -> Plug.Conn.request_url(conn) end

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

  defp scrubbers do
    case Process.get(@scrubber_pdict_key) do
      nil ->
        defaults = resolve_scrubbers([])
        Process.put(@scrubber_pdict_key, defaults)
        defaults

      map ->
        map
    end
  end

  @doc """
  Default scrubbing for a single `%Plug.Conn{}` field.

    * `:body` — scrubs a `params`-shaped map via `scrub_map/2`; non-maps pass
      through unchanged (so `%Plug.Conn.Unfetched{}` is preserved).
    * `:headers` — drops sensitive `req_headers` case-insensitively. Accepts
      both the list-of-tuples shape (preserved on output) and a map (drops
      sensitive keys via `drop_keys/2`).
    * `:cookies` — drops *all* cookies, returning `%{}`.
    * `:url` — returns the URL unchanged.

  Used by `scrub/1` and `scrub_request_url/1` for fields the user has not
  overridden via `put_conn_scrubber/1`, and available for custom scrubbers
  that want to compose the default behavior:

      defmodule MyScrubber do
        def scrub_params(conn) do
          Sentry.Scrubber.scrub(:body, conn.params)
          |> Map.drop(["my_secret_field"])
        end
      end
  """
  @doc since: "13.1.1"
  @spec scrub(:body | :headers | :cookies | :url, term()) :: term()
  def scrub(:body, params) when is_map(params) and not is_struct(params),
    do: do_scrub_map(params, @default_scrubbed_param_keys)

  def scrub(:body, other), do: other

  def scrub(:headers, headers) when is_list(headers), do: drop_sensitive_req_headers(headers)
  def scrub(:headers, headers) when is_map(headers), do: drop_keys(headers)

  def scrub(:cookies, _cookies), do: %{}

  def scrub(:url, url) when is_binary(url), do: url

  @doc """
  Scrubs a `%Plug.Conn{}` using the current process's registered scrubbers.

  When `put_conn_scrubber/1` has been called for this process, applies the
  resolved body, header, and cookie scrubbers to the corresponding conn
  fields. Otherwise falls back to `scrub/2` for each field.
  """
  @doc since: "13.1.1"
  @spec scrub(Plug.Conn.t()) :: Plug.Conn.t()
  def scrub(conn) when is_struct(conn, Plug.Conn) do
    %{
      conn
      | cookies: scrubbers().cookie_scrubber.(conn),
        req_headers: headers_to_list(scrubbers().header_scrubber.(conn)),
        params: scrubbers().body_scrubber.(conn)
    }
  end

  @doc """
  Returns the request URL for `conn`, scrubbed by the current process's
  registered `:url_scrubber`. Falls back to `scrub(:url, url)`.
  """
  @doc since: "13.1.1"
  @spec scrub_request_url(Plug.Conn.t()) :: String.t()
  def scrub_request_url(conn) when is_struct(conn, Plug.Conn) do
    scrubbers().url_scrubber.(conn)
  end

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

  ## Internal recursion

  defp do_scrub_map(map, keys) do
    Map.new(map, fn {key, value} -> {key, scrub_value(key, value, keys)} end)
  end

  defp do_scrub_list(list, keys) do
    Enum.map(list, fn value ->
      cond do
        is_struct(value) -> value |> Map.from_struct() |> do_scrub_map(keys)
        is_map(value) -> do_scrub_map(value, keys)
        is_list(value) -> do_scrub_list(value, keys)
        true -> value
      end
    end)
  end

  defp scrub_value(key, value, keys) do
    cond do
      key in keys -> @scrubbed_value
      is_binary(value) and value =~ credit_card_regex() -> @scrubbed_value
      is_struct(value) -> value |> Map.from_struct() |> do_scrub_map(keys)
      is_map(value) -> do_scrub_map(value, keys)
      is_list(value) -> do_scrub_list(value, keys)
      true -> value
    end
  end

  defp credit_card_regex, do: ~r/^(?:\d[ -]*?){13,16}$/
end
