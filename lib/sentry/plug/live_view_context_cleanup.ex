if Code.ensure_loaded?(Plug) do
  defmodule Sentry.Plug.LiveViewContextCleanup do
    @moduledoc false

    @behaviour Plug

    alias Sentry.Plug.LiveViewContext

    @impl Plug
    def init(opts), do: opts

    @impl Plug
    def call(conn, _opts) do
      Plug.Conn.register_before_send(conn, &LiveViewContext.delete_session_key/1)
    end
  end
end
