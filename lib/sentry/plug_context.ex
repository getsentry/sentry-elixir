defmodule Sentry.PlugContext do
  @moduledoc """
  This module adds Sentry context metadata during the request in a Plug
  application. It includes defaults for scrubbing sensitive data, and
  options for customizing it by default.

  It is intended for usage with `Sentry.PlugCapture` as metadata added here
  will appear in events captured.

  ### Sending Post Body Params

  In order to send post body parameters you should first scrub them of sensitive
  information. By default, they will be scrubbed with
  `Sentry.Plug.default_body_scrubber/1`. It can be overridden by passing
  the `body_scrubber` option, which accepts a `Plug.Conn` and returns a map
  to send.  Setting `:body_scrubber` to `nil` will not send any data back.
  If you would like to make use of Sentry's default scrubber behavior in a custom
  scrubber, it can be called directly.  An example configuration may look like
  the following:

      def scrub_params(conn) do
        # Makes use of the default body_scrubber to avoid sending password
        # and credit card information in plain text.  To also prevent sending
        # our sensitive "my_secret_field" and "other_sensitive_data" fields,
        # we simply drop those keys.
        Sentry.PlugContext.default_body_scrubber(conn)
        |> Map.drop(["my_secret_field", "other_sensitive_data"])
      end

  Then pass it into Sentry.Plug:

      plug Sentry.PlugContext, body_scrubber: &MyModule.scrub_params/1

  You can also pass it in as a `{module, fun}` like so:

      plug Sentry.PlugContext, body_scrubber: {MyModule, :scrub_params}

  *Please Note*: If you are sending large files you will want to scrub them out.

  ### Headers Scrubber

  By default Sentry will scrub Authorization and Authentication headers from all
  requests before sending them. It can be configured similarly to the body params
  scrubber, but is configured with the `:header_scrubber` key.

      def scrub_headers(conn) do
        # default is: Sentry.Plug.default_header_scrubber(conn)
        #
        # We do not want to include Content-Type or User-Agent in reported
        # headers, so we drop them.
        Enum.into(conn.req_headers, %{})
        |> Map.drop(["content-type", "user-agent"])
      end

  Then pass it into Sentry.Plug:

      plug Sentry.PlugContext, header_scrubber: &MyModule.scrub_headers/1

  It can also be passed in as a `{module, fun}` like so:

      plug Sentry.PlugContext, header_scrubber: {MyModule, :scrub_headers}

  ### Cookie Scrubber

  By default Sentry will scrub all cookies before sending events.
  It can be configured similarly to the headers scrubber, but is configured with the `:cookie_scrubber` key.

  To configure scrubbing, we can set all configuration keys:

  plug Sentry.PlugContext, header_scrubber: &MyModule.scrub_headers/1,
    body_scrubber: &MyModule.scrub_params/1, cookie_scrubber: &MyModule.scrub_cookies/1

  ### Including Request Identifiers

  If you're using Phoenix, Plug.RequestId, or another method to set a request ID
  response header, and would like to include that information with errors
  reported by Sentry.PlugContext, the `:request_id_header` option allows you to set
  which header key Sentry should check.  It will default to "x-request-id",
  which Plug.RequestId (and therefore Phoenix) also default to.

      plug Sentry.PlugContext, request_id_header: "application-request-id"
  """

  if Code.ensure_loaded?(Plug) do
    @behaviour Plug
  end

  @default_scrubbed_param_keys ["password", "passwd", "secret"]
  @default_scrubbed_header_keys ["authorization", "authentication", "cookie"]
  @credit_card_regex ~r/^(?:\d[ -]*?){13,16}$/
  @scrubbed_value "*********"
  @default_plug_request_id_header "x-request-id"

  def init(opts) do
    opts
  end

  def call(conn, opts) do
    request = build_request_interface_data(conn, opts)
    Sentry.Context.set_request_context(request)
    conn
  end

  @spec build_request_interface_data(Plug.Conn.t(), keyword()) :: map()
  def build_request_interface_data(conn, opts) do
    body_scrubber = Keyword.get(opts, :body_scrubber, {__MODULE__, :default_body_scrubber})

    header_scrubber = Keyword.get(opts, :header_scrubber, {__MODULE__, :default_header_scrubber})

    cookie_scrubber = Keyword.get(opts, :cookie_scrubber, {__MODULE__, :default_cookie_scrubber})

    request_id = Keyword.get(opts, :request_id_header) || @default_plug_request_id_header

    conn =
      Plug.Conn.fetch_cookies(conn)
      |> Plug.Conn.fetch_query_params()

    %{
      url: Plug.Conn.request_url(conn),
      method: conn.method,
      data: handle_data(conn, body_scrubber),
      query_string: conn.query_string,
      cookies: handle_data(conn, cookie_scrubber),
      headers: handle_data(conn, header_scrubber),
      env: %{
        "REMOTE_ADDR" => remote_address(conn.remote_ip),
        "REMOTE_PORT" => Plug.Conn.get_peer_data(conn).port,
        "SERVER_NAME" => conn.host,
        "SERVER_PORT" => conn.port,
        "REQUEST_ID" => Plug.Conn.get_resp_header(conn, request_id) |> List.first()
      }
    }
  end

  defp remote_address(address) do
    address
    |> :inet.ntoa()
    |> case do
      {:error, _} ->
        ""

      address ->
        to_string(address)
    end
  end

  defp handle_data(_conn, nil), do: %{}

  defp handle_data(conn, {module, fun}) do
    apply(module, fun, [conn])
  end

  defp handle_data(conn, fun) when is_function(fun) do
    fun.(conn)
  end

  @spec default_cookie_scrubber(Plug.Conn.t()) :: map()
  def default_cookie_scrubber(_conn) do
    %{}
  end

  @spec default_header_scrubber(Plug.Conn.t()) :: map()
  def default_header_scrubber(conn) do
    Enum.into(conn.req_headers, %{})
    |> Map.drop(@default_scrubbed_header_keys)
  end

  @spec default_body_scrubber(Plug.Conn.t()) :: map()
  def default_body_scrubber(conn) do
    scrub_map(conn.params, @default_scrubbed_param_keys)
  end

  @doc """
  Recursively scrubs a map that may have nested maps or lists

  Accepts a list of keys to scrub, and a list of options to configure

  ### Options
    * `:scrubbed_values_regular_expressions` - A list of regular expressions.
    Any binary values within the map that match any of the regular expressions
    will be scrubbed. Defaults to `[~r/^(?:\d[ -]*?){13,16}$/]`.
    * `:scrubbed_value` - The value to replace scrubbed values with.
    Defaults to `"*********"`.
  """
  @spec scrub_map(map(), list(String.t()), keyword()) :: map()
  def scrub_map(map, scrubbed_keys, opts \\ []) do
    scrubbed_values_regular_expressions =
      Keyword.get(opts, :scrubbed_values_regular_expressions, [@credit_card_regex])

    scrubbed_value = Keyword.get(opts, :scrubbed_value, @scrubbed_value)

    Enum.into(map, %{}, fn {key, value} ->
      value =
        cond do
          Enum.member?(scrubbed_keys, key) ->
            scrubbed_value

          is_binary(value) &&
              Enum.any?(scrubbed_values_regular_expressions, &Regex.match?(&1, value)) ->
            scrubbed_value

          is_map(value) && Map.has_key?(value, :__struct__) ->
            Map.from_struct(value)
            |> scrub_map(scrubbed_keys, opts)

          is_map(value) ->
            scrub_map(value, scrubbed_keys, opts)

          is_list(value) ->
            scrub_list(value, scrubbed_keys, opts)

          true ->
            value
        end

      {key, value}
    end)
  end

  @spec scrub_list(list(), list(String.t()), keyword()) :: list()
  defp scrub_list(list, scrubbed_keys, opts) do
    Enum.map(list, fn value ->
      cond do
        is_map(value) && Map.has_key?(value, :__struct__) ->
          value
          |> Map.from_struct()
          |> scrub_map(scrubbed_keys, opts)

        is_map(value) ->
          scrub_map(value, scrubbed_keys, opts)

        is_list(value) ->
          scrub_list(value, scrubbed_keys, opts)

        true ->
          value
      end
    end)
  end
end
