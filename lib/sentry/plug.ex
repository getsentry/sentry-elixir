defmodule Sentry.Plug do
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
        |> Enum.filter(fn ({key, val} -> 
          key in ~w(password passwd secret credit_card) ||
          Regex.match?(~r/^(?:\d[ -]*?){13,16}$r/, val) # Matches Credit Cards
        end)
        |> Enum.into(%{})
      end

  Then pass it into Sentry.Plug

      use Sentry.Plug, scrubber: scrub_params\1

  You can also pass it in as a `{module, fun}` like so

      use Sentry.Plug, scrubber: {MyModule, :scrub_params}

  ### Headers Scrubber

  By default we will scrub Authorization and Authentication headers from all requests before sending them. 

  """



  defmacro __using__(env) do
    scrubber = Keyword.get(env, :scrubber, nil)

    quote do
      defp handle_errors(conn, %{kind: kind, reason: reason, stack: stack}) do
        request = Sentry.Plug.build_request_interface_data(conn, unquote(scrubber))
        exception = Exception.normalize(kind, reason, stack)
        Sentry.capture_exception(exception, [stacktrace: stack, request: request])
      end
    end
  end

  def build_request_interface_data(%Plug.Conn{} = conn, scrubber) do
    conn = conn
            |> Plug.Conn.fetch_cookies
            |> Plug.Conn.fetch_query_params

    %{
      url: "#{conn.scheme}://#{conn.host}:#{conn.port}#{conn.request_path}",
      method: conn.method,
      data: handle_request_data(conn, scrubber),
      query_string: conn.query_string,
      cookies: conn.req_cookies,
      headers: Enum.into(conn.req_headers, %{}) |> scrub_headers(),
      env: %{
        "REMOTE_ADDR" => remote_address(conn.remote_ip),
        "REMOTE_PORT" => remote_port(conn.peer),
        "SERVER_NAME" => conn.host,
        "SERVER_PORT" => conn.port,
      }
    }
  end

  def remote_address(address) do
    address
    |> :inet.ntoa()
    |> to_string()
  end

  def remote_port({_, port}), do: port

  defp handle_request_data(_conn, nil), do: %{}
  defp handle_request_data(conn, {module, fun}) do
    apply(module, fun, [conn])
  end
  defp handle_request_data(conn, fun) when is_function(fun) do
    fun.(conn)
  end

  ## TODO also reject too big

  defp scrub_headers(data) do
    Map.drop(data, ~w(authorization authentication))
  end
end
