if(Code.ensure_loaded?(Plug), do:

defmodule Sentry.Plug do
  @default_scrubbed_param_keys ["password", "passwd", "secret"]
  @default_scrubbed_header_keys ["authorization", "authentication"]
  @credit_card_regex ~r/^(?:\d[ -]*?){13,16}$/
  @scrubbed_value "*********"

  @moduledoc """
  Provides basic funcitonality to handle Plug.ErrorHandler

  #### Usage

  Add the following to your router.ex:

      use Plug.ErrorLogger
      use Sentry.Plug

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
        Sentry.Plug.default_body_scrubber(conn)
        |> Map.drop(["my_secret_field", "other_sensitive_data"])
      end

  Then pass it into Sentry.Plug:

      use Sentry.Plug, body_scrubber: &scrub_params/1

  You can also pass it in as a `{module, fun}` like so:

      use Sentry.Plug, body_scrubber: {MyModule, :scrub_params}

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

      use Sentry.Plug, header_scrubber: &scrub_headers/1

  It can also be passed in as a `{module, fun}` like so:

      use Sentry.Plug, header_scrubber: {MyModule, :scrub_headers}

  To configure scrubbing body and header data, we can set both configuration keys:

      use Sentry.Plug, header_scrubber: &scrub_headers/1, body_scrubber: &scrub_params/1

  ### Including Request Identifiers

  If you're using Phoenix, Plug.RequestId, or another method to set a request ID
  response header, and would like to include that information with errors
  reported by Sentry.Plug, the `:request_id_header` option allows you to set
  which header key Sentry should check.  It will default to "x-request-id",
  which Plug.RequestId (and therefore Phoenix) also default to.

      use Sentry.Plug, request_id_header: "application-request-id"
  """

  @default_plug_request_id_header "x-request-id"


  defmacro __using__(env) do
    body_scrubber = Keyword.get(env, :body_scrubber, {__MODULE__, :default_body_scrubber})
    header_scrubber = Keyword.get(env, :header_scrubber, {__MODULE__, :default_header_scrubber})
    request_id_header = Keyword.get(env, :request_id_header)

    quote do
      # Ignore 404s for Plug routes
      defp handle_errors(conn, %{reason: %FunctionClauseError{function: :do_match}}) do
        nil
      end

      if :code.is_loaded(Phoenix) do
        # Ignore 404s for Phoenix routes
        defp handle_errors(conn, %{reason: %Phoenix.Router.NoRouteError{}}) do
          nil
        end
      end

      defp handle_errors(conn, %{kind: kind, reason: reason, stack: stack}) do
        opts = [body_scrubber: unquote(body_scrubber),
                 header_scrubber: unquote(header_scrubber),
                 request_id_header: unquote(request_id_header)]
        request = Sentry.Plug.build_request_interface_data(conn, opts)
        exception = Exception.normalize(kind, reason, stack)
        Sentry.capture_exception(exception, [stacktrace: stack, request: request, event_source: :plug])
      end
    end
  end

  @spec build_request_interface_data(Plug.Conn.t, keyword()) :: map()
  def build_request_interface_data(%Plug.Conn{} = conn, opts) do
    body_scrubber = Keyword.get(opts, :body_scrubber)
    header_scrubber = Keyword.get(opts, :header_scrubber)
    request_id = Keyword.get(opts, :request_id_header) || @default_plug_request_id_header

    conn = Plug.Conn.fetch_cookies(conn)
           |> Plug.Conn.fetch_query_params

    %{
      url: "#{conn.scheme}://#{conn.host}:#{conn.port}#{conn.request_path}",
      method: conn.method,
      data: handle_data(conn, body_scrubber),
      query_string: conn.query_string,
      cookies: conn.req_cookies,
      headers: handle_data(conn, header_scrubber),
      env: %{
        "REMOTE_ADDR" => remote_address(conn.remote_ip),
        "REMOTE_PORT" => remote_port(conn.peer),
        "SERVER_NAME" => conn.host,
        "SERVER_PORT" => conn.port,
        "REQUEST_ID" => Plug.Conn.get_resp_header(conn, request_id) |> List.first,
      }
    }
  end

  defp remote_address(address) do
    address
    |> :inet.ntoa()
    |> to_string()
  end

  defp remote_port({_, port}), do: port

  defp handle_data(_conn, nil), do: %{}
  defp handle_data(conn, {module, fun}) do
    apply(module, fun, [conn])
  end
  defp handle_data(conn, fun) when is_function(fun) do
    fun.(conn)
  end

  @spec default_header_scrubber(Plug.Conn.t) :: map()
  def default_header_scrubber(conn) do
    Enum.into(conn.req_headers, %{})
    |> Map.drop(@default_scrubbed_header_keys)
  end

  @spec default_body_scrubber(Plug.Conn.t) :: map()
  def default_body_scrubber(conn) do
    scrub_map(conn.params)
  end

  defp scrub_map(map) do
    Enum.map(map, fn {key, value} ->
      value = cond do
        Enum.member?(@default_scrubbed_param_keys, key) ->
          @scrubbed_value
        is_binary(value) && Regex.match?(@credit_card_regex, value) ->
          @scrubbed_value
        is_map(value) && !Map.has_key?(value, :__struct__) ->
          scrub_map(value)
        true ->
          value
      end

      {key, value}
    end)
    |> Enum.into(%{})
  end
end)
