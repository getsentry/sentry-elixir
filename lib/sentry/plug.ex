defmodule Sentry.Plug do
  defmacro __using__(_env) do
    quote do
      def call(conn, opts) do
        try do
          super(conn, opts)
        catch
          kind, reason ->
            Sentry.Plug.__catch__(conn, kind, reason)
        end
      end
    end
  end

  def __catch__(_conn, :error, %Plug.Conn.WrapperError{} = wrapper) do
    %{conn: conn, kind: kind, reason: reason, stack: stack} = wrapper
    __catch__(conn, kind, reason, stack)
  end

  def __catch__(conn, kind, reason) do
    __catch__(conn, kind, reason, System.stacktrace())
  end

  def __catch__(conn, kind, reason, stack) do
    request = Sentry.Plug.build_request_interface_data(conn)
    exception = Exception.normalize(kind, reason, stack)
    Sentry.capture_exception(exception, [stacktrace: stack, request: request])
    :erlang.raise(kind, reason, stack)
  end

  def build_request_interface_data(%Plug.Conn{} = conn) do
    conn = conn
            |> Plug.Conn.fetch_cookies
            |> Plug.Conn.fetch_query_params

    %{
      url: conn.request_path,
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
