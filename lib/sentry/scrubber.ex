defmodule Sentry.Scrubber do
  # Bound above the @moduledoc, which interpolates them.
  #
  # The denylist required by the Sentry Data Collection spec, matched as a
  # case-insensitive substring of the key name rather than for equality, so that
  # "auth" covers "Authorization" and "X-Auth-Token".
  # https://develop.sentry.dev/sdk/foundations/client/data-collection/
  @default_scrubbed_param_keys [
    "auth",
    "token",
    "secret",
    "password",
    "passwd",
    "pwd",
    "key",
    "jwt",
    "bearer",
    "sso",
    "saml",
    "csrf",
    "xsrf",
    "credentials",
    "session",
    "sid",
    "identity"
  ]

  @default_scrubbed_header_keys ["authorization", "authentication", "cookie"]

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
  and arbitrary maps) are the denylist required by the
  [Sentry Data Collection spec](https://develop.sentry.dev/sdk/foundations/client/data-collection/):

  #{Enum.map_join(@default_scrubbed_param_keys, "\n", &"  * `\"#{&1}\"`")}

  A key counts as sensitive when any of those terms appears anywhere in its
  name, compared case-insensitively — so `"auth"` covers both `"Authorization"`
  and `"X-Auth-Token"`.

  The default sensitive *header* keys are:

  #{Enum.map_join(@default_scrubbed_header_keys, "\n", &"  * `\"#{&1}\"`")}

  Values matching a credit-card-like pattern (13–16 digits, optionally
  separated by spaces or dashes) are also replaced with the placeholder.

  ## Custom scrubbing

  Add your own terms to the parameter denylist with the `:scrubber`
  configuration, which extends the list above:

      config :sentry, scrubber: [param_keys: ["internal_ref"]]

  The map/query/header functions also accept an optional `:keys` option that
  replaces the list outright for that call. Precedence is `:keys` > the
  `scrubber: [param_keys: ...]` configuration > `default_param_keys/0`. This
  makes it possible to compose custom scrubbers on top of the defaults:

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
      a raw query string, `:url_scrubbed` derives the field from the URL the
      registered `:url_scrubber` returns, and `:private_allow_list` keeps only
      the registered allow-listed keys of the field (see
      `default_private_allow_list/0` and the `:private_allow_list` option of
      `put_conn_scrubber/1`), dropping everything else.

  By default `scrub/1` redacts `cookies`, `req_headers`, `params`, and
  `body_params` (the configurable fields — `body_params` shares the
  `:body_scrubber` with `params`, so it honors the same registered scrubber and
  is emptied when `body_scrubber` is `nil`), clears `req_cookies` and `assigns`
  to `%{}`, scrubs `query_params` and `path_params` as params-shaped maps, derives `request_path`,
  `path_info` and `query_string` from the scrubbed URL, and reduces `private` to
  its allow-listed keys (`default_private_allow_list/0`). `assigns` is cleared
  wholesale because auth libraries (Guardian, Pow, Coherence) routinely store
  decoded tokens, full user structs, and session data there, where no key-based
  heuristic redacts safely. `private` keeps only the allow-listed framework
  metadata and drops everything else (notably `:plug_session`).

  The defaults can be overridden per call with `scrub(conn, overrides)`, where
  `overrides` is a `field: strategy` keyword list merged over the attribute —
  for example `scrub(conn, assigns: :clear)`.

  The request URL itself is not a conn field, so callers that report it (such as
  `Sentry.PlugContext`) fetch the registered `:url_scrubber` with `get/1` and
  apply it to the conn. The conn's own URL-derived fields are covered here: a
  custom `:url_scrubber` that redacts a path segment redacts it in
  `request_path` and `path_info` too, wherever the conn itself is reported.
  Registering `url_scrubber: nil` opts out of that, though `query_string` is
  still scrubbed against the sensitive key list.
  """

  @moduledoc since: "13.1.0"

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
  # `:url_scrubbed` -> derive from the URL the registered `:url_scrubber` returns,
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
    path_params: :params,
    query_string: :url_scrubbed,
    request_path: :url_scrubbed,
    path_info: :url_scrubbed,
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
          param_keys: [String.t()],
          private_allow_list: [atom()]
        }

  @enforce_keys @scrubber_names
  defstruct @scrubber_names ++
              [
                param_keys: @default_scrubbed_param_keys,
                private_allow_list: @default_private_allow_list
              ]

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
  `:param_keys` and `:private_allow_list` default to the corresponding
  `:scrubber` configuration values.
  """
  @type conn_scrubber_opts :: [
          body_scrubber: field_scrubber(),
          header_scrubber: field_scrubber(),
          cookie_scrubber: field_scrubber(),
          url_scrubber: field_scrubber(),
          param_keys: [String.t()],
          private_allow_list: [atom()]
        ]

  @doc """
  The placeholder string used to replace scrubbed values.
  """
  @doc since: "13.1.0"
  @spec scrubbed_value() :: String.t()
  def scrubbed_value, do: @scrubbed_value

  @doc """
  Returns the SDK default list of sensitive parameter keys.

  This is the denylist required by the
  [Sentry Data Collection spec](https://develop.sentry.dev/sdk/foundations/client/data-collection/),
  matched as a case-insensitive substring of the key name. The
  `scrubber: [param_keys: ...]` configuration option extends it.
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
    keys = param_keys(opts)

    query
    |> URI.query_decoder()
    |> Enum.map(fn {key, value} ->
      cond do
        sensitive_key?(key, keys) -> {key, @scrubbed_value}
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
      param_keys: Keyword.get_lazy(opts, :param_keys, &configured_param_keys/0),
      private_allow_list:
        Keyword.get_lazy(opts, :private_allow_list, &configured_private_allow_list/0)
    }
  end

  # The user-configured key lists. Read at most once per scrubber construction,
  # and `scrubber/0` memoizes the struct per process, so the recursive scrubbing
  # functions never reach the config store per map node.
  defp configured_param_keys,
    do: @default_scrubbed_param_keys ++ Sentry.Config.scrubber()[:param_keys]

  defp configured_private_allow_list, do: Sentry.Config.scrubber()[:conn_private_allow_list]

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
        {m, f, args} |> mfa_to_fun() |> wrap_custom_scrubber(field)

      {:ok, {m, f}} when is_atom(m) and is_atom(f) ->
        {m, f, []} |> mfa_to_fun() |> wrap_custom_scrubber(field)

      {:ok, fun} when is_function(fun, 1) ->
        wrap_custom_scrubber(fun, field)
    end
  end

  defp wrap_custom_scrubber(scrubber, :url) do
    fn conn ->
      case call_url_scrubber(scrubber, conn) do
        {:ok, url} when is_binary(url) ->
          url

        {:ok, _other} ->
          Sentry.LoggerUtils.warning(
            "url_scrubber function returned a non-binary value; falling back to the default URL scrubber"
          )

          scrub(conn, :url)

        {:error, error} ->
          Sentry.LoggerUtils.warning(
            "url_scrubber function failed: #{inspect(error)}; falling back to the default URL scrubber"
          )

          scrub(conn, :url)
      end
    end
  end

  defp wrap_custom_scrubber(scrubber, _field), do: scrubber

  defp call_url_scrubber(scrubber, conn) do
    try do
      {:ok, scrubber.(conn)}
    rescue
      error -> {:error, error}
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
  them per call. This includes `request_path`, `path_info` and `query_string`,
  which are derived from the URL the registered `:url_scrubber` returns. The
  reported request URL is not a conn field; callers scrub that separately by
  applying the `:url_scrubber` from `get/1` (whose default is
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
  configurable scrubber struct-key, `:clear` (replace with `%{}`), `:params`
  (params-shaped scrub of that field), `:query_string` (redact sensitive params
  from that raw query string), `:url_scrubbed` (derive that field from the
  scrubbed URL), or `:private_allow_list` (keep only the allow-listed keys):

      Sentry.Scrubber.scrub(conn, assigns: :clear, query_params: :params)
  """
  @doc since: "13.1.0"
  @spec scrub(map(), [option()]) :: map()
  @spec scrub(list(), [option()]) :: list()
  @spec scrub(term(), [option()]) :: term()
  @spec scrub(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  @spec scrub(Plug.Conn.t(), :body | :headers | :cookies | :url) :: term()

  def scrub(map, opts) when is_map(map) and not is_struct(map) and is_list(opts) do
    keys = param_keys(opts)
    opts = Keyword.put_new(opts, :keys, keys)

    Map.new(map, fn {key, value} ->
      {key, if(sensitive_key?(key, keys), do: @scrubbed_value, else: scrub(value, opts))}
    end)
  end

  def scrub(conn, overrides) when is_struct(conn, Plug.Conn) and is_list(overrides) do
    fields = Keyword.merge(@scrubbable_conn_fields, overrides)

    uri = if url_scrubbed?(fields), do: scrubbed_uri(conn)

    Enum.reduce(fields, conn, fn {field, strategy}, acc ->
      Map.replace(acc, field, normalize(field, scrub_conn_field(conn, field, strategy, uri)))
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
  #   * `:url_scrubbed` — derives THIS field from the URL produced by the
  #     registered `:url_scrubber`, so a custom scrubber governs the conn's own
  #     path as well as the reported request URL
  defp scrub_conn_field(conn, field, :url_scrubbed, uri), do: url_scrubbed(conn, field, uri)

  defp scrub_conn_field(conn, field, strategy, _uri), do: scrub_conn_field(conn, field, strategy)

  defp scrub_conn_field(conn, _field, scrubber_key) when scrubber_key in @scrubber_names,
    do: get(scrubber_key).(conn)

  defp scrub_conn_field(_conn, _field, :clear), do: %{}

  defp scrub_conn_field(conn, field, :params),
    do: scrub_params_value(Map.fetch!(conn, field))

  defp scrub_conn_field(conn, field, :query_string),
    do: scrub_query_string(Map.fetch!(conn, field))

  defp scrub_conn_field(conn, field, :private_allow_list),
    do: Map.take(Map.fetch!(conn, field), scrubber().private_allow_list)

  defp url_scrubbed?(fields), do: Enum.any?(fields, &match?({_field, :url_scrubbed}, &1))

  # Applies the resolved `:url_scrubber` and parses the result. Custom URL
  # scrubbers are wrapped by `resolve_scrubber/3`, so exceptions and non-binary
  # results have already fallen back to the default URL scrubber. The non-binary
  # branch remains defensive; `URI.parse/1` returns a `%URI{}` for any binary,
  # and unparseable input lands in `:path`, which over-redacts rather than
  # under-redacts.
  defp scrubbed_uri(conn) do
    case get(:url_scrubber).(conn) do
      url when is_binary(url) -> URI.parse(url)
      _other -> nil
    end
  end

  defp url_scrubbed(conn, :request_path, uri), do: scrubbed_path(conn, uri)

  defp url_scrubbed(conn, :path_info, uri) do
    case scrubbed_path(conn, uri) do
      path when path == conn.request_path ->
        conn.path_info

      path ->
        path |> split_path() |> Enum.drop(length(conn.script_name))
    end
  end

  defp url_scrubbed(conn, :query_string, uri) do
    conn |> scrubbed_query(uri) |> scrub_query_string()
  end

  defp url_scrubbed(conn, field, _uri), do: Map.fetch!(conn, field)

  # `URI.parse/1` yields `path: nil` for a URL without one, and `nil` is not a
  # valid `:request_path` — it makes `Plug.Conn.request_url/1` raise on the
  # scrubbed conn. A scrubber that collapsed the URL to a bare host meant to
  # redact the path, so that becomes "" rather than the original path.
  defp scrubbed_path(conn, nil), do: conn.request_path
  defp scrubbed_path(_conn, %URI{path: path}) when is_binary(path), do: path
  defp scrubbed_path(_conn, %URI{}), do: ""

  defp scrubbed_query(conn, nil), do: conn.query_string
  defp scrubbed_query(_conn, %URI{query: query}) when is_binary(query), do: query
  defp scrubbed_query(_conn, %URI{}), do: ""

  # Splits a request path into `:path_info` segments the way Plug adapters do.
  # Deliberately does not percent-decode: adapters store `path_info` encoded and
  # `Plug.Router.Utils.decode_path_info!/1` decodes at match time.
  defp split_path(path), do: for(segment <- String.split(path, "/"), segment != "", do: segment)

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

  # Resolves the sensitive parameter keys for a scrubbing call. An explicit
  # `:keys` option wins; otherwise they come from the current process's scrubber,
  # which is config-backed and memoized by `scrubber/0`.
  defp param_keys(opts), do: Keyword.get_lazy(opts, :keys, fn -> scrubber().param_keys end)

  # Matches a key against the sensitive-key list the way the Sentry Data
  # Collection spec requires: a partial, case-insensitive match, so a key counts
  # as sensitive when any listed term appears anywhere in its name. Maps built
  # from structs via `Map.from_struct/1` have atom keys, so atoms are compared by
  # their string form.
  defp sensitive_key?(key, keys) when is_atom(key) and not is_nil(key),
    do: key |> Atom.to_string() |> sensitive_key?(keys)

  defp sensitive_key?(key, keys) when is_binary(key) do
    downcased = String.downcase(key)
    Enum.any?(keys, &String.contains?(downcased, String.downcase(&1)))
  end

  defp sensitive_key?(_key, _keys), do: false

  defp credit_card_regex, do: ~r/^(?:\d[ -]*?){13,16}$/
end
