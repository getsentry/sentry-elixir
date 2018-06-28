defmodule Sentry.Context do
  @moduledoc """
    Provides functionality to store user, tags, extra, and breadcrumbs context when an
    event is reported. The contexts will be fetched and merged into the event when it is sent.

    When calling Sentry.Context, the Process Dictionary is used to store this state.
    This imposes some limitations. The state will only exist within
    the current process, and the context will die with the process.

    For example, if you add context inside your controller and an
    error happens in a Task, that context will not be included.

    A common use-case is to set context within Plug or Phoenix applications, as each
    request is its own process, and so any stored context will be included should an
    error be reported within that request process. Example:

      # post_controller.ex
      def index(conn, _params) do
        Sentry.Context.set_user_context(%{id: conn.assigns.user_id})
        posts = Blog.list_posts()
        render(conn, "index.html", posts: posts)
      end
  """
  @process_dictionary_key :sentry_context
  @user_key :user
  @tags_key :tags
  @extra_key :extra
  @request_key :request
  @breadcrumbs_key :breadcrumbs

  def get_all do
    context = get_context()

    %{
      user: Map.get(context, @user_key, %{}),
      tags: Map.get(context, @tags_key, %{}),
      extra: Map.get(context, @extra_key, %{}),
      request: Map.get(context, @request_key, %{}),
      breadcrumbs: Map.get(context, @breadcrumbs_key, []) |> Enum.reverse() |> Enum.to_list()
    }
  end

  def set_extra_context(map) when is_map(map) do
    get_context()
    |> set_context(@extra_key, map)
  end

  def set_user_context(map) when is_map(map) do
    get_context()
    |> set_context(@user_key, map)
  end

  def set_tags_context(map) when is_map(map) do
    get_context()
    |> set_context(@tags_key, map)
  end

  def set_http_context(map) when is_map(map) do
    get_context()
    |> set_context(@request_key, map)
  end

  def clear_all do
    Process.delete(@process_dictionary_key)
  end

  defp get_context do
    Process.get(@process_dictionary_key) || %{}
  end

  def add_breadcrumb(list) when is_list(list) do
    add_breadcrumb(Enum.into(list, %{}))
  end

  def add_breadcrumb(map) when is_map(map) do
    map = Map.put_new(map, "timestamp", Sentry.Util.unix_timestamp())

    context =
      get_context()
      |> Map.update(@breadcrumbs_key, [map], &[map | &1])

    Process.put(@process_dictionary_key, context)
  end

  defp set_context(current, key, new) when is_map(current) and is_map(new) do
    merged_context =
      current
      |> Map.get(key, %{})
      |> Map.merge(new)

    new_context = Map.put(current, key, merged_context)
    Process.put(@process_dictionary_key, new_context)
  end

  def context_keys do
    [@breadcrumbs_key, @tags_key, @user_key, @extra_key]
  end
end
