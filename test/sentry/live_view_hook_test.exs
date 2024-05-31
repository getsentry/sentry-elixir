defmodule SentryTest.Live do
  use Phoenix.LiveView

  on_mount Sentry.LiveViewHook

  def render(assigns) do
    ~H"""
    <h1>Testing Sentry hooks</h1>
    <.live_component module={SentryTest.LiveComponent} id="lc" />
    """
  end

  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  def handle_event("refresh", _params, socket) do
    {:noreply, socket}
  end

  def handle_info(:test_message, socket) do
    {:noreply, socket}
  end
end

defmodule SentryTest.LiveComponent do
  use Phoenix.LiveComponent

  def render(assigns) do
    ~H"<p>I'm a LiveComponent</p>"
  end
end

defmodule SentryTest.Router do
  use Phoenix.Router
  import Phoenix.LiveView.Router

  scope "/" do
    live "/hook_test", SentryTest.Live
  end
end

defmodule SentryTest.Endpoint do
  use Phoenix.Endpoint, otp_app: :sentry

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [:peer_data, :uri, :user_agent]]

  plug SentryTest.Router
end

defmodule Sentry.LiveViewHookTest do
  use Sentry.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint SentryTest.Endpoint

  setup_all do
    Application.put_env(:sentry, SentryTest.Endpoint,
      secret_key_base: "TMnue44VMTf1VmyD6SYKR30cqKpHluHOFZGXcVkC33hKVVKTVZ1HBQLLLLLLLLLL",
      live_view: [signing_salt: "F8ftIAbYdeTzhwgl"]
    )

    pid = start_supervised!(SentryTest.Endpoint)
    Process.link(pid)
    :ok
  end

  setup do
    %{conn: build_conn()}
  end

  test "attaches the right context", %{conn: conn} do
    conn = Plug.Conn.put_req_header(conn, "user-agent", "sentry-testing 1.0")

    {:ok, view, html} = live(conn, "/hook_test")
    assert html =~ "<h1>Testing Sentry hooks</h1>"

    context1 = get_sentry_context(view)

    assert "phx-" <> _ = context1.extra.socket_id
    assert context1.request.url == "http://www.example.com/hook_test"
    assert context1.extra.user_agent == "sentry-testing 1.0"

    assert [
             %{category: "web.live_view.params"} = params_breadcrumb,
             %{category: "web.live_view.mount"} = mount_breadcrumb
           ] = context1.breadcrumbs

    assert mount_breadcrumb.message == "Mounted live view"
    assert mount_breadcrumb.data == %{}

    assert params_breadcrumb.message == "http://www.example.com/hook_test"
    assert params_breadcrumb.data == %{params: %{}, uri: "http://www.example.com/hook_test"}

    # Send an event and test the new breadcrumb.

    assert render_hook(view, :refresh, %{force: true}) =~ "Testing Sentry hooks"

    context2 = get_sentry_context(view)
    assert Map.take(context1, [:extra, :request]) == Map.take(context2, [:extra, :request])
    assert [event_breadcrumb, ^params_breadcrumb, ^mount_breadcrumb] = context2.breadcrumbs
    assert event_breadcrumb.category == "web.live_view.event"
    assert event_breadcrumb.message == ~s("refresh")
    assert event_breadcrumb.data == %{params: %{"force" => true}, event: "refresh"}

    # Send a message and test the new breadcrumb.
    send(view.pid, :test_message)
    assert render(view) =~ "Testing Sentry hooks"

    context3 = get_sentry_context(view)
    assert Map.take(context1, [:extra, :request]) == Map.take(context3, [:extra, :request])

    assert [info_breadcrumb, ^event_breadcrumb, ^params_breadcrumb, ^mount_breadcrumb] =
             context3.breadcrumbs

    assert info_breadcrumb.category == "web.live_view.info"
    assert info_breadcrumb.message == ~s(:test_message)
  end

  test "works with live components", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/hook_test")
    assert html =~ "<h1>Testing Sentry hooks</h1>"
    assert html =~ "I&#39;m a LiveComponent"
  end

  defp get_sentry_context(view) do
    {:dictionary, pdict} = Process.info(view.pid, :dictionary)

    assert {:ok, sentry_context} =
             pdict
             |> Keyword.fetch!(:"$logger_metadata$")
             |> Map.fetch(Sentry.Context.__logger_metadata_key__())

    sentry_context
  end
end
