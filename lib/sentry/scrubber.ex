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

  `scrub/1` redacts a conn by applying, to each field listed in the
  `@scrubbable_conn_fields` attribute, that field's *strategy*. A strategy is
  either:

    * a configurable scrubber (`:cookie_scrubber`, `:header_scrubber`,
      `:body_scrubber`) — resolved per process via `put_conn_scrubber/1`
      (typically from `Sentry.PlugContext.call/2`), falling back to the SDK
      default `scrub(conn, field)` clause when none is registered, or
    * a fixed tag — `:clear` replaces the field with `%{}`, `:params` scrubs the
      field as a params-shaped map, `:query_string` redacts sensitive params from
      a raw query string, and `:private_allow_list` keeps only the registered
      allow-listed keys of the field (see `default_private_allow_list/0` and the
      `:private_allow_list` option of `put_conn_scrubber/1`), dropping everything
      else.

  By default `scrub/1` redacts `cookies`, `req_headers`, `params`, and
  `body_params` (the configurable fields — `body_params` shares the
  `:body_scrubber` with `params`, so it honors the same registered scrubber and
  is emptied when `body_scrubber` is `nil`), clears `req_cookies` and `assigns`
  to `%{}`, scrubs `query_params` as a params-shaped map, and reduces `private`
  to its allow-listed keys (`default_private_allow_list/0`). `assigns` is cleared
  wholesale because auth libraries (Guardian, Pow, Coherence) routinely store
  decoded tokens, full user structs, and session data there, where no key-based
  heuristic redacts safely. `private` keeps only the allow-listed framework
  metadata and drops everything else (notably `:plug_session`).

  The defaults can be overridden per call with `scrub(conn, overrides)`, where
  `overrides` is a `field: strategy` keyword list merged over the attribute —
  for example `scrub(conn, assigns: :clear)`. The request URL is not a conn
  field, so callers fetch the registered `:url_scrubber` with `get/1` and apply
  it to the conn.
  """

  @moduledoc since: "13.1.0"

  @default_scrubbed_param_keys ["password", "passwd", "secret"]
  @default_scrubbed_header_keys ["authorization", "authentication", "cookie"]
  @scrubbed_value "*********"
  @scrubber_pdict_key {__MODULE__, :scrubber}
  @scrubber_names [:body_scrubber, :header_scrubber, :cookie_scrubber, :url_scrubber]

  # Keys retained when a `%Plug.Conn{}`'s `:private` map is scrubbed with the
  # `:private_allow_list` strategy. These are Phoenix's routing/render metadata
  # — safe, high-signal breadcrumbs for triaging which controller/action failed.
  # Anything not listed (e.g. `:plug_session`, which holds decoded session data)
  # is dropped. This is the SDK default; the `scrubber: [conn_private_allow_list: ...]`
  # config option exposes it as a user-configurable option.
  @default_private_allow_list [
    :phoenix_controller,
    :phoenix_action,
    :phoenix_endpoint,
    :phoenix_router,
    :phoenix_view,
    :phoenix_layout,
    :phoenix_format,
    :phoenix_template,
    :phoenix_router_url,
    :phoenix_static_url
  ]

  # Default `field -> strategy` mapping applied by `scrub/1` (overridable per
  # call via `scrub(conn, overrides)`). A strategy is either a configurable
  # scrubber struct-key (resolved per process via `get/1`) or a fixed tag:
  # `:clear` -> `%{}`, `:params` -> params-shaped scrub (Unfetched-safe),
  # `:query_string` -> redact sensitive params from the raw query string,
  # `:private_allow_list` -> keep only the registered allow-listed keys.
  # Add an entry to make a new conn field scrubbed by default.
  #
  # `assigns` is cleared wholesale because auth libraries (Guardian, Pow,
  # Coherence) routinely store decoded tokens, full user structs, and session
  # data there — there is no reliable key-based heuristic to redact it safely.
  # `private` mixes sensitive data (e.g. `:plug_session`) with high-signal
  # framework metadata (Phoenix routing), so it uses an allow-list instead of
  # clearing wholesale — see `@default_private_allow_list`.
  @scrubbable_conn_fields [
    cookies: :cookie_scrubber,
    req_cookies: :clear,
    req_headers: :header_scrubber,
    params: :body_scrubber,
    body_params: :body_scrubber,
    query_params: :params,
    query_string: :query_string,
    assigns: :clear,
    private: :private_allow_list
  ]

  @typedoc """
  A resolved set of per-field scrubbers for a `%Plug.Conn{}`.

  Each scrubber field holds a 1-arity function that takes the conn and returns
  the scrubbed value for the corresponding field. `private_allow_list` holds the
  keys retained by the `:private_allow_list` strategy. Built by
  `put_conn_scrubber/1` from `t:conn_scrubber_opts/0` and stored in the process
  dictionary.
  """
  @type t :: %__MODULE__{
          body_scrubber: (Plug.Conn.t() -> term()),
          header_scrubber: (Plug.Conn.t() -> term()),
          cookie_scrubber: (Plug.Conn.t() -> term()),
          url_scrubber: (Plug.Conn.t() -> String.t()),
          private_allow_list: [atom()]
        }

  @enforce_keys @scrubber_names
  defstruct @scrubber_names ++ [private_allow_list: @default_private_allow_list]

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
    * `nil` — disables the scrubber; map-shaped fields are replaced with `%{}`,
      and `:url` falls back to the request URL unchanged
  """
  @type field_scrubber ::
          (Plug.Conn.t() -> term()) | {module(), atom()} | nil

  @typedoc """
  Options accepted by `put_conn_scrubber/1`.

  Each `*_scrubber` key, when omitted, falls back to the field's default
  scrubber — the matching `scrub(conn, field)` clause of `scrub/2`.
  `:private_allow_list` defaults to `default_private_allow_list/0`.
  """
  @type conn_scrubber_opts :: [
          body_scrubber: field_scrubber(),
          header_scrubber: field_scrubber(),
          cookie_scrubber: field_scrubber(),
          url_scrubber: field_scrubber(),
          private_allow_list: [atom()]
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
  Returns the default list of `%Plug.Conn{}` `:private` keys retained by the
  `:private_allow_list` scrubbing strategy.

  These are Phoenix's routing/render metadata keys, kept because they are
  high-signal, non-sensitive breadcrumbs for triaging errors. This is the
  default for the `scrubber: [conn_private_allow_list: ...]` configuration option.
  """
  @doc since: "13.2.0"
  @spec default_private_allow_list() :: [atom()]
  def default_private_allow_list, do: @default_private_allow_list

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
  resolves each missing key to the field's default scrubber (the
  `{__MODULE__, :scrub, [field]}` MFA, i.e. the matching `scrub(conn, field)`
  clause), and stores the resolved scrubbers in the process dictionary.

  The registration lives for the lifetime of the calling process — typically
  the request process when registered from `Sentry.PlugContext.call/2`. Used
  by other parts of the SDK (notably `Sentry.PlugCapture`) so all conn
  scrubbing honors the same configuration the user passed to
  `plug Sentry.PlugContext`.

  Returns `:ok`.
  """
  @doc since: "13.2.0"
  @spec put_conn_scrubber(conn_scrubber_opts()) :: :ok
  def put_conn_scrubber(opts) when is_list(opts) do
    Process.put(@scrubber_pdict_key, new(opts))
    :ok
  end

  @doc """
  Builds a resolved `t:t/0` set of per-field scrubbers from the given options.

  Accepts the same `:body_scrubber`, `:header_scrubber`, `:cookie_scrubber`,
  and `:url_scrubber` keys as `put_conn_scrubber/1`. Each missing key falls
  back to the field's default scrubber (the matching `scrub(conn, field)`
  clause). Called with no arguments, `new/0` returns the all-defaults scrubber.

  Unlike `put_conn_scrubber/1`, this only constructs the struct — it does not
  register it for the current process.
  """
  @doc since: "13.2.0"
  @spec new(conn_scrubber_opts()) :: t()
  def new(opts \\ []) when is_list(opts) do
    %__MODULE__{
      body_scrubber: resolve_scrubber(opts, :body_scrubber, :body),
      header_scrubber: resolve_scrubber(opts, :header_scrubber, :headers),
      cookie_scrubber: resolve_scrubber(opts, :cookie_scrubber, :cookies),
      url_scrubber: resolve_scrubber(opts, :url_scrubber, :url),
      private_allow_list: Keyword.get(opts, :private_allow_list, @default_private_allow_list)
    }
  end

  # Resolves a per-field scrubber option into a `(conn -> term)` function. A
  # missing option falls back to the field's default scrubber, expressed as an
  # `{module, function, args}` MFA that captures the matching `scrub(conn, field)`
  # clause. `nil` disables scrubbing for the field: the map-shaped fields become
  # `%{}`, while `:url` (a string field) falls back to the request URL unchanged.
  defp resolve_scrubber(opts, opt_name, field) do
    case Keyword.fetch(opts, opt_name) do
      :error ->
        mfa_to_fun({__MODULE__, :scrub, [field]})

      {:ok, nil} ->
        pass_through(field)

      {:ok, {m, f, args}} when is_atom(m) and is_atom(f) and is_list(args) ->
        mfa_to_fun({m, f, args})

      {:ok, {m, f}} when is_atom(m) and is_atom(f) ->
        mfa_to_fun({m, f, []})

      {:ok, fun} when is_function(fun, 1) ->
        fun
    end
  end

  defp pass_through(:url), do: fn conn -> Plug.Conn.request_url(conn) end
  defp pass_through(_field), do: fn _conn -> %{} end

  defp mfa_to_fun({m, f, args}), do: fn conn -> apply(m, f, [conn | args]) end

  @spec scrubber() :: t()
  defp scrubber do
    case Process.get(@scrubber_pdict_key) do
      nil ->
        defaults = new()
        Process.put(@scrubber_pdict_key, defaults)
        defaults

      %__MODULE__{} = scrubbers ->
        scrubbers
    end
  end

  @doc """
  Returns the current process's resolved scrubber function for the given field.

  `key` is one of `#{inspect(@scrubber_names)}`. Returns the scrubber registered
  via `put_conn_scrubber/1`, or the field's default if none was registered. The
  returned function takes a `%Plug.Conn{}` and returns the scrubbed value, so
  callers apply it as `Sentry.Scrubber.get(:url_scrubber).(conn)`.
  """
  @doc since: "13.2.0"
  @spec get(atom()) :: (Plug.Conn.t() -> term())
  def get(key) when key in @scrubber_names, do: Map.get(scrubber(), key)

  @doc """
  Scrubs a `%Plug.Conn{}` or a plain map.

  Given a `%Plug.Conn{}`, scrubs each field listed in `@scrubbable_conn_fields`
  according to its strategy — see the "Scrubbing a `%Plug.Conn{}`" section in
  the module docs and `scrub/2` for the per-field defaults and how to override
  them per call. The request URL is not a conn field; callers scrub it
  separately by applying the `:url_scrubber` from `get/1` (whose default is
  `scrub(conn, :url)`).

  Given a plain map, recursively scrubs it with the default sensitive keys —
  equivalent to `scrub(map, [])`. Any other struct is converted to a map and
  scrubbed the same way, so a sensitive field can't slip through unredacted —
  for example when the struct is inspected into stacktrace frame vars. See
  `scrub/2`.
  """
  @doc since: "13.2.0"
  @spec scrub(Plug.Conn.t()) :: Plug.Conn.t()
  @spec scrub(map()) :: map()
  @spec scrub(term()) :: term()

  def scrub(conn) when is_struct(conn, Plug.Conn), do: scrub(conn, [])

  def scrub(struct) when is_struct(struct), do: scrub(struct, [])

  def scrub(map) when is_map(map), do: scrub(map, [])

  def scrub(other), do: other

  @doc """
  Scrubs a value with the given options, dispatching on the value's type.

  ## Scrubbing a map, list, or leaf value — `scrub(value, opts)`

  Recursively scrubs a map: any value whose key is in the configured sensitive
  key list is replaced with the placeholder, and the remaining values are
  scrubbed in turn. Lists are scrubbed element-wise, structs are scrubbed as
  maps, and credit-card-shaped binaries are replaced with the placeholder. Any
  other leaf value is returned unchanged.

  Accepts the same `:keys` option as the other scrubbing functions:

    * `:keys` - the list of sensitive keys to redact. Defaults to
      `default_param_keys/0`.

  ## Scrubbing a single `%Plug.Conn{}` field — `scrub(conn, field)`

  Extracts the given field from the `conn` and applies the SDK's *default*
  redaction for it. Each clause is what the field's default scrubber captures
  as a `{__MODULE__, :scrub, [field]}` MFA, and what `scrub/1` (conn fields)
  and `get/1` (URL) fall back to when no custom scrubber is registered:

    * `:body` — scrubs `conn.params` via `scrub/2`; non-map params (such as
      `%Plug.Conn.Unfetched{}`) pass through unchanged.
    * `:headers` — drops sensitive `conn.req_headers` case-insensitively,
      preserving the list-of-tuples shape.
    * `:cookies` — drops *all* cookies, returning `%{}`.
    * `:url` — scrubs sensitive query parameters from the request URL via
      `scrub_url/1`. To disable URL scrubbing, register a `:url_scrubber` of
      `nil` (or a custom one); see `Sentry.PlugContext`.

  Because these clauses are the defaults (not the registered scrubbers), a
  custom `:body_scrubber` can safely compose on the default behavior without
  recursing:

      defmodule MyScrubber do
        def scrub_params(conn) do
          conn
          |> Sentry.Scrubber.scrub(:body)
          |> Map.drop(["my_secret_field"])
        end
      end

  ## Scrubbing a whole `%Plug.Conn{}` with overrides — `scrub(conn, overrides)`

  Behaves like `scrub/1` but merges the `field: strategy` keyword `overrides`
  over the `@scrubbable_conn_fields` defaults, so a caller can scrub additional
  fields or change a field's strategy for that call. Strategies are a
  configurable scrubber struct-key, `:clear` (replace with `%{}`), or `:params`
  (params-shaped scrub of that field):

      Sentry.Scrubber.scrub(conn, assigns: :clear, query_params: :params)
  """
  @doc since: "13.1.0"
  @spec scrub(map(), [option()]) :: map()
  @spec scrub(list(), [option()]) :: list()
  @spec scrub(term(), [option()]) :: term()
  @spec scrub(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  @spec scrub(Plug.Conn.t(), :body | :headers | :cookies | :url) :: term()

  def scrub(map, opts) when is_map(map) and not is_struct(map) and is_list(opts) do
    keys = Keyword.get(opts, :keys, @default_scrubbed_param_keys)

    Map.new(map, fn {key, value} ->
      {key, if(sensitive_key?(key, keys), do: @scrubbed_value, else: scrub(value, opts))}
    end)
  end

  def scrub(conn, overrides) when is_struct(conn, Plug.Conn) and is_list(overrides) do
    @scrubbable_conn_fields
    |> Keyword.merge(overrides)
    |> Enum.reduce(conn, fn {field, strategy}, acc ->
      Map.replace(acc, field, normalize(field, scrub_conn_field(conn, field, strategy)))
    end)
  end

  def scrub(struct, opts)
      when is_struct(struct) and not is_struct(struct, Plug.Conn) and is_list(opts),
      do: struct |> Map.from_struct() |> scrub(opts)

  def scrub(list, opts) when is_list(list), do: Enum.map(list, &scrub(&1, opts))

  def scrub(value, opts) when is_binary(value) and is_list(opts),
    do: if(value =~ credit_card_regex(), do: @scrubbed_value, else: value)

  def scrub(value, opts) when is_list(opts), do: value

  # These are the SDK's default per-field scrubbers, captured as
  # `{__MODULE__, :scrub, [field]}` MFAs in `resolve_scrubber/3`. `scrub/1`
  # (conn fields) and `get/1` (URL) apply the *registered* scrubbers; these
  # clauses are the defaults those registrations fall back to.
  def scrub(conn, :body) when is_struct(conn, Plug.Conn),
    do: scrub_params_value(conn.params)

  def scrub(conn, :headers) when is_struct(conn, Plug.Conn) do
    Enum.reject(conn.req_headers, fn
      {name, _value} when is_binary(name) ->
        String.downcase(name) in @default_scrubbed_header_keys

      _ ->
        false
    end)
  end

  def scrub(conn, :cookies) when is_struct(conn, Plug.Conn), do: %{}

  def scrub(conn, :url) when is_struct(conn, Plug.Conn),
    do: scrub_url(Plug.Conn.request_url(conn))

  # Resolves a single conn field's strategy (from `@scrubbable_conn_fields` or a
  # `scrub(conn, overrides)` override) to its scrubbed value:
  #
  #   * a configurable scrubber struct-key — resolved per-process via `get/1`,
  #     honoring any `put_conn_scrubber/1` registration
  #   * `:clear` — replaces the field with `%{}`
  #   * `:params` — scrubs THIS field (read via `Map.fetch!/2`) as a
  #     params-shaped map, leaving `%Plug.Conn.Unfetched{}` untouched
  #   * `:query_string` — redacts sensitive params from THIS field (a raw query
  #     string) via `scrub_query_string/1`
  #   * `:private_allow_list` — keeps only the registered allow-listed keys of
  #     THIS field (a map), dropping everything else
  defp scrub_conn_field(conn, _field, scrubber_key) when scrubber_key in @scrubber_names,
    do: get(scrubber_key).(conn)

  defp scrub_conn_field(_conn, _field, :clear), do: %{}

  defp scrub_conn_field(conn, field, :params),
    do: scrub_params_value(Map.fetch!(conn, field))

  defp scrub_conn_field(conn, field, :query_string),
    do: scrub_query_string(Map.fetch!(conn, field))

  defp scrub_conn_field(conn, field, :private_allow_list),
    do: Map.take(Map.fetch!(conn, field), scrubber().private_allow_list)

  # Scrubs a params-shaped value with the default sensitive keys, leaving
  # `%Plug.Conn.Unfetched{}` (and any non-plain-map) untouched. Shared by the
  # `:body` default clause and the `:params` strategy.
  defp scrub_params_value(value) when is_map(value) and not is_struct(value), do: scrub(value)
  defp scrub_params_value(value), do: value

  # Coerces a per-field scrubber result into the shape its `%Plug.Conn{}` field
  # requires. A header scrubber may return a map (the documented convention —
  # see `Sentry.PlugContext`'s `default_header_scrubber/1`), but `req_headers`
  # must be a list of `{name, value}` tuples, so `scrub/1` stays structurally
  # valid. Other fields pass through unchanged.
  defp normalize(:req_headers, headers) do
    if is_list(headers), do: headers, else: Map.to_list(headers)
  end

  defp normalize(_field, value), do: value

  # Matches a map key against the configured sensitive-key list. The list is
  # string-based (HTTP params), but maps built from structs via `Map.from_struct/1`
  # have atom keys, so atoms are also compared by their string form.
  defp sensitive_key?(key, keys),
    do: key in keys or (is_atom(key) and Atom.to_string(key) in keys)

  defp credit_card_regex, do: ~r/^(?:\d[ -]*?){13,16}$/
end
