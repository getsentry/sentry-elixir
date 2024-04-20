defmodule Sentry.ErrorView do
  use Phoenix.Component

  import Phoenix.HTML, only: [raw: 1]

  def render(_, _) do
    case Sentry.get_last_event_id_and_source() do
      {event_id, :plug} ->
        opts =
          %{title: "Testing", eventId: event_id}
          |> Jason.encode!()

        assigns = %{opts: opts}

        ~H"""
        <script src="https://browser.sentry-cdn.com/5.9.1/bundle.min.js" integrity="sha384-/x1aHz0nKRd6zVUazsV6CbQvjJvr6zQL2CHbQZf3yoLkezyEtZUpqUNnOLW9Nt3v" crossorigin="anonymous"></script>
        <script>
        Sentry.init({ dsn: '<%= inspect(Sentry.Config.dsn()) %>' });
        Sentry.showReportDialog(<%= raw @opts %>)
        </script>
        """

      _ ->
        "error"
    end
  end
end
