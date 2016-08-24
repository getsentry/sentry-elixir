defmodule Sentry.Plug do
  defmacro __using__(_env) do
    quote do
      defp handle_errors(conn, %{kind: kind, reason: reason, stack: stack}) do
        request = Sentry.Plug.build_request_interface_data(conn)
        exception = Exception.normalize(kind, reason, stack)
        Sentry.capture_exception(exception, [stacktrace: stack, request: request])
      end
    end
  end

  def build_request_interface_data(%Plug.Conn{} = conn) do
    conn = conn
            |> Plug.Conn.fetch_cookies
            |> Plug.Conn.fetch_query_params

    %{
      url: "#{conn.scheme}://#{conn.host}:#{conn.port}#{conn.request_path}",
      method: conn.method,
      data: %{
      },
      query_string: conn.query_string,
      cookies: conn.req_cookies,
      headers: Enum.into(conn.req_headers, %{}),
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
end
