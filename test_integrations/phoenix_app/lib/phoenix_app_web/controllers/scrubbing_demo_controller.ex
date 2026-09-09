defmodule PhoenixAppWeb.ScrubbingDemoController do
  @moduledoc """
  Fixture for the parameter-scrubbing e2e spec.

  `index/2` renders a page to interact with: a reset form to fill in and submit,
  and links carrying a secret in the path. `reset_password/2` never matches the
  params those send, so Phoenix raises a `Phoenix.ActionClauseError` whose
  message embeds the whole `%Plug.Conn{}`. That is what puts `request_path`,
  `path_info`, `path_params` and `query_string` into the reported event,
  alongside the request interface, so the spec can assert on each of them.
  """

  use PhoenixAppWeb, :controller

  plug Sentry.PlugContext,
       [url_scrubber: {__MODULE__, :scrub_url}] when action == :reset_password

  plug :tag_run when action == :reset_password

  # The spec owns the exact bytes it wants on the wire, so the links echo the
  # query this page was opened with rather than rebuilding it — rebuilding would
  # re-encode it and hide what the scrubber does or does not rewrite. That puts
  # the secrets in this page's own URL, which is the point: the browser sends it
  # as the `Referer` of everything clicked from here.
  def index(conn, params) do
    path_secret = Map.get(params, "path_secret", "pathsecret")
    reset_path = "/scrubbing-demo/reset-password/#{path_secret}"
    query = drop_param(conn.query_string, "path_secret")

    render(conn, :index,
      form_action: reset_path,
      probe_href: "#{reset_path}?#{query}",
      forwarded_href: "/scrubbing-demo/forwarded/reset-password/#{path_secret}?#{query}",
      keep: Map.get(params, "keep", ""),
      run: Map.get(params, "e2e_run", "")
    )
  end

  defp drop_param(query_string, name) do
    query_string
    |> String.split("&")
    |> Enum.reject(&String.starts_with?(&1, "#{name}="))
    |> Enum.join("&")
  end

  def reset_password(conn, %{"confirmed" => true}), do: json(conn, %{status: "ok"})

  @doc """
  Redacts the token segment of the demo path on top of the SDK's default URL
  scrubbing, the way an application would for a URL that carries a secret.
  """
  def scrub_url(conn) do
    conn
    |> Sentry.PlugContext.default_url_scrubber()
    |> String.replace(
      ~r{/reset-password/[^/?]+},
      "/reset-password/#{Sentry.Scrubber.scrubbed_value()}"
    )
  end

  defp tag_run(conn, _opts) do
    case conn.params do
      %{"e2e_run" => run_id} when is_binary(run_id) ->
        Sentry.Context.set_tags_context(%{"e2e_run" => run_id})
        conn

      _ ->
        conn
    end
  end
end
