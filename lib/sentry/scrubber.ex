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
  @conn_scrubber_pdict_key {__MODULE__, :conn_scrubber}

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
          cookie_scrubber: field_scrubber()
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

  Accepts the same `:body_scrubber`, `:header_scrubber`, and `:cookie_scrubber`
  keys that `Sentry.PlugContext` takes as plug options, resolves each missing
  key to its corresponding `default_*_scrubber/1`, and stores the resolved
  scrubbers in the process dictionary.

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
    Process.put(@conn_scrubber_pdict_key, resolve_conn_scrubber_opts(opts))
    :ok
  end

  defp resolve_conn_scrubber_opts(opts) do
    %{
      body_scrubber: Keyword.get(opts, :body_scrubber, {__MODULE__, :default_body_scrubber}),
      header_scrubber: Keyword.get(opts, :header_scrubber, {__MODULE__, :default_header_scrubber}),
      cookie_scrubber: Keyword.get(opts, :cookie_scrubber, {__MODULE__, :default_cookie_scrubber})
    }
  end

  @doc """
  Scrubs a `%Plug.Conn{}` using the current process's registered scrubbers.

  When `put_conn_scrubber/1` has been called for this process, applies the
  resolved body, header, and cookie scrubbers to the corresponding conn
  fields. Otherwise falls back to `default_conn_scrubber/1`.
  """
  @doc since: "13.1.1"
  @spec scrub_conn(Plug.Conn.t()) :: Plug.Conn.t()
  def scrub_conn(conn) when is_struct(conn, Plug.Conn) do
    case Process.get(@conn_scrubber_pdict_key) do
      nil ->
        default_conn_scrubber(conn)

      %{body_scrubber: body, header_scrubber: header, cookie_scrubber: cookie} ->
        %{
          conn
          | cookies: apply_field_scrubber(conn, cookie),
            req_headers: headers_to_list(apply_field_scrubber(conn, header)),
            params: apply_field_scrubber(conn, body)
        }
    end
  end

  @doc """
  Default scrubber for `%Plug.Conn{}` used by `scrub_conn/1` when no
  per-process scrubber is registered.

  Clears `cookies`, drops sensitive `req_headers` case-insensitively
  (preserving the list shape required by `Plug.Conn`), and scrubs `params`
  via `scrub_map/2`.
  """
  @doc since: "13.1.1"
  @spec default_conn_scrubber(Plug.Conn.t()) :: Plug.Conn.t()
  def default_conn_scrubber(conn) when is_struct(conn, Plug.Conn) do
    %{
      conn
      | cookies: %{},
        req_headers: drop_sensitive_req_headers(conn.req_headers),
        params: scrub_params(conn.params)
    }
  end

  @doc """
  Default `:body_scrubber` used by `put_conn_scrubber/1` when no override is
  provided.

  Scrubs `conn.params` via `scrub_map/2`. The default scrubbed keys are:

  #{Enum.map_join(@default_scrubbed_param_keys, "\n", &"  * `\"#{&1}\"`")}
  """
  @doc since: "13.1.1"
  @spec default_body_scrubber(Plug.Conn.t()) :: map()
  def default_body_scrubber(conn) when is_struct(conn, Plug.Conn) do
    scrub_map(conn.params)
  end

  @doc """
  Default `:header_scrubber` used by `put_conn_scrubber/1` when no override is
  provided.

  Drops sensitive entries from `conn.req_headers` via `drop_keys/2` after
  converting to a map. The default scrubbed keys are:

  #{Enum.map_join(@default_scrubbed_header_keys, "\n", &"  * `\"#{&1}\"`")}
  """
  @doc since: "13.1.1"
  @spec default_header_scrubber(Plug.Conn.t()) :: map()
  def default_header_scrubber(conn) when is_struct(conn, Plug.Conn) do
    conn.req_headers
    |> Map.new()
    |> drop_keys()
  end

  @doc """
  Default `:cookie_scrubber` used by `put_conn_scrubber/1` when no override is
  provided.

  Drops *all* cookies — returns an empty map regardless of input.
  """
  @doc since: "13.1.1"
  @spec default_cookie_scrubber(Plug.Conn.t()) :: map()
  def default_cookie_scrubber(_conn) do
    %{}
  end

  defp apply_field_scrubber(_conn, nil), do: %{}
  defp apply_field_scrubber(conn, {mod, fun}), do: apply(mod, fun, [conn])
  defp apply_field_scrubber(conn, fun) when is_function(fun, 1), do: fun.(conn)

  defp headers_to_list(headers) when is_map(headers), do: Map.to_list(headers)
  defp headers_to_list(headers) when is_list(headers), do: headers

  defp drop_sensitive_req_headers(headers) when is_list(headers) do
    Enum.reject(headers, fn
      {name, _value} when is_binary(name) ->
        String.downcase(name) in @default_scrubbed_header_keys

      _ ->
        false
    end)
  end

  defp drop_sensitive_req_headers(other), do: other

  defp scrub_params(params) when is_map(params) and not is_struct(params),
    do: do_scrub_map(params, @default_scrubbed_param_keys)

  defp scrub_params(other), do: other

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
