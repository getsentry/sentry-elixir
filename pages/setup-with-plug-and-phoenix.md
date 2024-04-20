# Setup with Plug and Phoenix

You can capture errors in Plug (and Phoenix) applications with `Sentry.PlugContext` and `Sentry.PlugCapture`. `Sentry.PlugContext` adds contextual metadata from the current request which is then included in errors that are captured and reported by `Sentry.PlugCapture`.

## For Phoenix Applications

If you are using Phoenix:

  1. Add `Sentry.PlugCapture` above the `use Phoenix.Endpoint` line in your endpoint file
  1. Add `Sentry.PlugContext` below `Plug.Parsers`

```diff
 defmodule MyAppWeb.Endpoint
+  use Sentry.PlugCapture
   use Phoenix.Endpoint, otp_app: :my_app

   # ...

   plug Plug.Parsers,
     parsers: [:urlencoded, :multipart, :json],
     pass: ["*/*"],
     json_decoder: Phoenix.json_library()

+  plug Sentry.PlugContext
```

If you're also using [Phoenix LiveView](https://github.com/phoenixframework/phoenix_live_view), consider also setting up your LiveViews to use the `Sentry.LiveViewHook` hook:

```elixir
defmodule MyAppWeb do
  def live_view do
    quote do
      use Phoenix.LiveView

      on_mount Sentry.LiveViewHook
    end
  end
end
```

### Capturing User Feedback

If you would like to capture user feedback as described [here](https://docs.sentry.io/platforms/elixir/enriching-events/user-feedback/), the `Sentry.get_last_event_id_and_source/0` function can be used to see if Sentry has sent an event within the current Plug process (and get the source of that event). `:plug` will be the source for events coming from `Sentry.PlugCapture`. The options described in the Sentry documentation linked above can be encoded into the response as well.

An example Phoenix application setup that displays the user feedback form on 500 responses on requests accepting HTML could look like this:

```elixir
defmodule MyAppWeb.ErrorView do
  # ...

  def render("500.html", _assigns) do
    case Sentry.get_last_event_id_and_source() do
      {event_id, :plug} when is_binary(event_id) ->
        opts = Jason.encode!(%{eventId: event_id})

        ~E"""
          <script src="https://browser.sentry-cdn.com/5.9.1/bundle.min.js" integrity="sha384-/x1aHz0nKRd6zVUazsV6CbQvjJvr6zQL2CHbQZf3yoLkezyEtZUpqUNnOLW9Nt3v" crossorigin="anonymous"></script>
          <script>
            Sentry.init({ dsn: '<%= Sentry.Config.dsn() %>' });
            Sentry.showReportDialog(<%= raw opts %>)
          </script>
        """

      _ ->
        "Error"
    end
  end
end
```

## For Plug Applications

If you are in a non-Phoenix Plug application:

  1. Add `Sentry.PlugCapture` at the top of your Plug application
  1. Add `Sentry.PlugContext` below `Plug.Parsers` (if it is in your stack)

```diff
 defmodule MyApp.Router do
   use Plug.Router
+  use Sentry.PlugCapture

   # ...

   plug Plug.Parsers,
     parsers: [:urlencoded, :multipart]

+  plug Sentry.PlugContext
```
