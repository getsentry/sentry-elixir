defmodule PhoenixAppWeb.TracingTestLive do
  @moduledoc """
  LiveView for testing Sentry tracing integration via Playwright e2e tests.

  This LiveView provides simple actions that generate traceable events:
  - mount: Initial page load (static render + WebSocket connection)
  - handle_event: User interaction via LiveView event
  - handle_params: URL parameter changes
  """
  use PhoenixAppWeb, :live_view

  require OpenTelemetry.Tracer, as: Tracer

  alias PhoenixApp.{Repo, Accounts.User}

  @impl true
  def mount(_params, _session, socket) do
    socket =
      assign(socket,
        counter: 0,
        data: nil,
        last_action: "mount"
      )

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _url, socket) do
    action = Map.get(params, "action", "default")

    socket =
      socket
      |> assign(:last_action, "handle_params:#{action}")

    {:noreply, socket}
  end

  @impl true
  def handle_event("increment", _params, socket) do
    # Simple event that triggers a span
    new_counter = socket.assigns.counter + 1

    {:noreply,
     socket
     |> assign(:counter, new_counter)
     |> assign(:last_action, "increment")}
  end

  @impl true
  def handle_event("fetch_data", _params, socket) do
    # Event that performs a database query (generates child spans)
    Tracer.with_span "liveview.fetch_data" do
      users = Repo.all(User)
      count = length(users)

      Tracer.with_span "liveview.process_users" do
        data = %{
          user_count: count,
          timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
        }

        {:noreply,
         socket
         |> assign(:data, data)
         |> assign(:last_action, "fetch_data")}
      end
    end
  end

  @impl true
  def handle_event("trigger_error", _params, _socket) do
    # Event that raises an error for testing error capture
    raise RuntimeError, "Test error from LiveView handle_event"
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="tracing-test-live" class="mx-auto max-w-2xl p-6">
      <h1 class="text-2xl font-bold mb-4">LiveView Tracing Test</h1>

      <div class="space-y-4">
        <div class="p-4 bg-gray-100 rounded">
          <p><strong>Counter:</strong> <span id="counter-value">{@counter}</span></p>
          <p><strong>Last Action:</strong> <span id="last-action">{@last_action}</span></p>
          <%= if @data do %>
            <p><strong>Data:</strong> <span id="data-value">{inspect(@data)}</span></p>
          <% end %>
        </div>

        <div class="space-x-2">
          <button
            id="increment-btn"
            phx-click="increment"
            class="px-4 py-2 bg-blue-500 text-white rounded hover:bg-blue-600"
          >
            Increment Counter
          </button>

          <button
            id="fetch-data-btn"
            phx-click="fetch_data"
            class="px-4 py-2 bg-green-500 text-white rounded hover:bg-green-600"
          >
            Fetch Data
          </button>

          <button
            id="trigger-error-btn"
            phx-click="trigger_error"
            class="px-4 py-2 bg-red-500 text-white rounded hover:bg-red-600"
          >
            Trigger Error
          </button>
        </div>

        <div class="mt-4">
          <.link
            id="params-link"
            patch={~p"/tracing-test?action=param_change"}
            class="text-blue-500 hover:underline"
          >
            Test handle_params (patch navigation)
          </.link>
        </div>
      </div>
    </div>
    """
  end
end
