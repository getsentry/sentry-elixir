defmodule Sentry.Plug do
  @default_scrubbed_param_keys ["password", "passwd", "secret"]
  @credit_card_regex ~r/^(?:\d[ -]*?){13,16}$/
  @scrubbed_value "*********"

  @moduledoc """
  Provides basic funcitonality to handle Plug.ErrorHandler

  #### Usage

  Add the following to your router.ex:
      
      use Plug.ErrorLogger
      use Sentry.Plug

  ### Sending Post Body Params

  In order to send post body parameters you need to first scrub them of sensitive information. To
  do so we ask you to pass a `scrubber` key which accepts a `Plug.Conn` and returns a map with keys 
  to send. 

      def scrub_params(conn) do
        conn.params # Make sure the params have been fetched.
        |> Map.to_list
        |> Enum.filter(fn ({key, val}) -> 
          key in ~w(password passwd secret credit_card) ||
          Regex.match?(~r/^(?:\d[ -]*?){13,16}$r/, val) # Matches Credit Cards
        end)
        |> Enum.into(%{})
      end

  Then pass it into Sentry.Plug

      use Sentry.Plug, scrubber: &scrub_params/1

  You can also pass it in as a `{module, fun}` like so

      use Sentry.Plug, scrubber: {MyModule, :scrub_params}

  *Please Note*: If you are sending large files you will want to scrub them out.

  ### Headers Scrubber

  By default we will scrub Authorization and Authentication headers from all requests before sending them. 

  ### Including Request Identifiers

  If you're using Phoenix, Plug.RequestId, or another method to set a request ID response header, and would like to include that information with errors reported by Sentry.Plug, the `:request_id_header` option allows you to set which header key Sentry should check.  It will default to "x-request-id", which Plug.RequestId (and therefore Phoenix) also default to.

      use Sentry.Plug, request_id_header: "application-request-id"
  """

  @default_plug_request_id_header "x-request-id"


  defmacro __using__(env) do
    scrubber = Keyword.get(env, :scrubber, {__MODULE__, :default_scrubber})
    request_id_header = Keyword.get(env, :request_id_header, nil)

    quote do
      defp handle_errors(conn, %{kind: kind, reason: reason, stack: stack}) do
        opts = [scrubber: unquote(scrubber), request_id_header: unquote(request_id_header)]
        request = Sentry.Plug.build_request_interface_data(conn, opts)
        exception = Exception.normalize(kind, reason, stack)
        Sentry.capture_exception(exception, [stacktrace: stack, request: request])
      end
    end
  end

  def build_request_interface_data(%{__struct__: Plug.Conn} = conn, opts) do
    scrubber = Keyword.get(opts, :scrubber)
    request_id = Keyword.get(opts, :request_id_header) || @default_plug_request_id_header

    conn = conn
            |> Plug.Conn.fetch_cookies
            |> Plug.Conn.fetch_query_params

    %{
      url: "#{conn.scheme}://#{conn.host}:#{conn.port}#{conn.request_path}",
      method: conn.method,
      data: handle_data(conn, scrubber),
      query_string: conn.query_string,
      cookies: conn.req_cookies,
      headers: Enum.into(conn.req_headers, %{}) |> scrub_headers(),
      env: %{
        "REMOTE_ADDR" => remote_address(conn.remote_ip),
        "REMOTE_PORT" => remote_port(conn.peer),
        "SERVER_NAME" => conn.host,
        "SERVER_PORT" => conn.port,
        "REQUEST_ID" => Plug.Conn.get_resp_header(conn, request_id) |> List.first,
      }
    }
  end

  def remote_address(address) do
    address
    |> :inet.ntoa()
    |> to_string()
  end

  def remote_port({_, port}), do: port

  defp handle_data(_conn, nil), do: %{}
  defp handle_data(conn, {module, fun}) do
    apply(module, fun, [conn])
  end
  defp handle_data(conn, fun) when is_function(fun) do
    fun.(conn)
  end

  ## TODO also reject too big

  defp scrub_headers(data) do
    Map.drop(data, ~w(authorization authentication))
  end

  def default_scrubber(conn) do
    conn.params
    |> Enum.map(fn({key, value}) ->
      value = cond do
        Enum.member?(@default_scrubbed_param_keys, key) -> @scrubbed_value
        Regex.match?(@credit_card_regex, value) -> @scrubbed_value
        true -> true
      end

      {key, value}
    end)
    |> Enum.into(%{})
  end
end
