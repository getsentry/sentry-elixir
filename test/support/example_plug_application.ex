defmodule Sentry.ExamplePlugApplication do
  use Plug.Router
  use Sentry.PlugCapture
  use Plug.ErrorHandler

  import ExUnit.Assertions

  plug Plug.Parsers, parsers: [:multipart, :urlencoded]
  plug Sentry.PlugContext
  plug :match
  plug :dispatch

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec([]) do
    Supervisor.child_spec(
      {Plug.Cowboy, scheme: :http, plug: __MODULE__, options: [port: 8003]},
      []
    )
  end

  get "/exit_route" do
    _ = conn
    exit(:test)
  end

  get "/throw_route" do
    _ = conn
    throw(:test)
  end

  get "/spawn_error_route" do
    {_pid, ref} = spawn_monitor(fn -> raise "Error" end)
    assert_receive {:DOWN, ^ref, _, _, _}
    send_resp(conn, 200, "")
  end

  match "/error_route" do
    _ = conn
    raise RuntimeError, "Error"
  end

  def handle_errors(conn, %{kind: _kind, reason: _reason, stack: _stack}) do
    response =
      case Sentry.get_last_event_id_and_source() do
        {event_id, :plug} ->
          opts =
            %{title: "Testing", eventId: event_id}
            |> Jason.encode!()

          """
          <script src="https://browser.sentry-cdn.com/5.9.1/bundle.min.js" integrity="sha384-/x1aHz0nKRd6zVUazsV6CbQvjJvr6zQL2CHbQZf3yoLkezyEtZUpqUNnOLW9Nt3v" crossorigin="anonymous"></script>
          <script>
          Sentry.init({ dsn: '#{inspect(Sentry.Config.dsn())}' });
          Sentry.showReportDialog(#{opts})
          </script>
          """

        _ ->
          "error"
      end

    send_resp(conn, conn.status, response)
  end
end
