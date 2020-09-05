defmodule Sentry.Context do
  @moduledoc """
    Provides functionality to store user, tags, extra, and breadcrumbs context when an
    event is reported. The contexts will be fetched and merged into the event when it is sent.

    When calling Sentry.Context, Logger metadata is used to store this state.
    This imposes some limitations. The metadata will only exist within
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

    It should be noted that the `set_*_context/1` functions merge with the
    existing context rather than entirely overwriting it.
  """
  @logger_metadata_key :sentry
  @user_key :user
  @tags_key :tags
  @extra_key :extra
  @request_key :request
  @breadcrumbs_key :breadcrumbs

  @doc """
  Retrieves all currently set context on the current process.

  ## Example

      iex> Sentry.Context.set_user_context(%{id: 123})
      iex> Sentry.Context.set_tags_context(%{message_id: 456})
      iex> Sentry.Context.get_all()
      %{
        user: %{id: 123},
        tags: %{message_id: 456},
        extra: %{},
        request: %{},
        breadcrumbs: []
      }
  """
  @spec get_all() :: %{
          user: map(),
          tags: map(),
          extra: map(),
          request: map(),
          breadcrumbs: list()
        }
  def get_all do
    context = get_sentry_context()

    %{
      user: Map.get(context, @user_key, %{}),
      tags: Map.get(context, @tags_key, %{}),
      extra: Map.get(context, @extra_key, %{}),
      request: Map.get(context, @request_key, %{}),
      breadcrumbs: Map.get(context, @breadcrumbs_key, []) |> Enum.reverse() |> Enum.to_list()
    }
  end

  @doc """
  Merges new fields into the `:extra` context, specific to the current process.

  This is used to set fields which should display when looking at a specific
  instance of an error.

  ## Example

      iex> Sentry.Context.set_extra_context(%{id: 123})
      :ok
      iex> Sentry.Context.set_extra_context(%{detail: "bad_error"})
      :ok
      iex> Sentry.Context.set_extra_context(%{message: "Oh no"})
      :ok
      iex> Sentry.Context.get_all()
      %{
        user: %{},
        tags: %{},
        extra: %{detail: "bad_error", id: 123, message: "Oh no"},
        request: %{},
        breadcrumbs: []
      }
  """
  @spec set_extra_context(map()) :: :ok
  def set_extra_context(map) when is_map(map) do
    set_context(@extra_key, map)
  end

  @doc """
  Merges new fields into the `:user` context, specific to the current process.

  This is used to set certain fields which identify the actor who experienced a
  specific instance of an error.

  ## Example

      iex> Sentry.Context.set_user_context(%{id: 123})
      :ok
      iex> Sentry.Context.set_user_context(%{username: "george"})
      :ok
      iex> Sentry.Context.get_all()
      %{
        user: %{id: 123, username: "george"},
        tags: %{},
        extra: %{},
        request: %{},
        breadcrumbs: []
      }
  """
  @spec set_user_context(map()) :: :ok
  def set_user_context(map) when is_map(map) do
    set_context(@user_key, map)
  end

  @doc """
  Merges new fields into the `:tags` context, specific to the current process.

  This is used to set fields which should display when looking at a specific
  instance of an error. These fields can also be used to search and filter on.

  ## Example

      iex> Sentry.Context.set_tags_context(%{id: 123})
      :ok
      iex> Sentry.Context.set_tags_context(%{other_id: 456})
      :ok
      iex> Sentry.Context.get_all()
      %{
          breadcrumbs: [],
          extra: %{},
          request: %{},
          tags: %{id: 123, other_id: 456},
          user: %{}
      }
  """
  @spec set_tags_context(map()) :: :ok
  def set_tags_context(map) when is_map(map) do
    set_context(@tags_key, map)
  end

  @doc """
  Merges new fields into the `:request` context, specific to the current
  process.

  This is used to set metadata that identifies the request associated with a
  specific instance of an error.

  ## Example

      iex(1)> Sentry.Context.set_request_context(%{id: 123})
      :ok
      iex(2)> Sentry.Context.set_request_context(%{url: "www.example.com"})
      :ok
      iex(3)> Sentry.Context.get_all()
      %{
          breadcrumbs: [],
          extra: %{},
          request: %{id: 123, url: "www.example.com"},
          tags: %{},
          user: %{}
      }
  """
  @spec set_request_context(map()) :: :ok
  def set_request_context(map) when is_map(map) do
    set_context(@request_key, map)
  end

  @doc """
  Clears all existing context for the current process.

  ## Example

      iex> Sentry.Context.set_tags_context(%{id: 123})
      :ok
      iex> Sentry.Context.clear_all()
      :ok
      iex> Sentry.Context.get_all()
      %{breadcrumbs: [], extra: %{}, request: %{}, tags: %{}, user: %{}}
  """
  def clear_all do
    :logger.update_process_metadata(%{sentry: %{}})
  end

  defp get_sentry_context do
    case :logger.get_process_metadata() do
      %{@logger_metadata_key => sentry} -> sentry
      %{} -> %{}
      :undefined -> %{}
    end
  end

  @doc """
  Adds a new breadcrumb to the `:breadcrumb` context, specific to the current
  process.

  Breadcrumbs are used to record a series of events that led to a specific
  instance of an error. Breadcrumbs can contain arbitrary key data to assist in
  understanding what happened before an error occurred.

  ## Example

      iex> Sentry.Context.add_breadcrumb(message: "first_event")
      :ok
      iex> Sentry.Context.add_breadcrumb(%{message: "second_event", type: "auth"})
      %{breadcrumbs: [%{:message => "first_event", "timestamp" => 1562007480}]}
      iex> Sentry.Context.add_breadcrumb(%{message: "response"})
      %{
          breadcrumbs: [
                %{:message => "second_event", :type => "auth", "timestamp" => 1562007505},
                %{:message => "first_event", "timestamp" => 1562007480}
              ]
      }
      iex> Sentry.Context.get_all()
      %{
          breadcrumbs: [
                %{:message => "first_event", "timestamp" => 1562007480},
                %{:message => "second_event", :type => "auth", "timestamp" => 1562007505},
                %{:message => "response", "timestamp" => 1562007517}
              ],
          extra: %{},
          request: %{},
          tags: %{},
          user: %{}
      }
  """
  @spec add_breadcrumb(keyword() | map()) :: :ok
  def add_breadcrumb(list) when is_list(list) do
    if Keyword.keyword?(list) do
      list
      |> Enum.into(%{})
      |> add_breadcrumb
    else
      raise ArgumentError, """
      Sentry.Context.add_breadcrumb/1 only accepts keyword lists or maps.
      Received a non-keyword list.
      """
    end
  end

  def add_breadcrumb(map) when is_map(map) do
    map = Map.put_new(map, "timestamp", Sentry.Util.unix_timestamp())

    sentry_metadata =
      get_sentry_context()
      |> Map.update(@breadcrumbs_key, [map], fn breadcrumbs ->
        breadcrumbs = [map | breadcrumbs]
        Enum.take(breadcrumbs, -1 * Sentry.Config.max_breadcrumbs())
      end)

    :logger.update_process_metadata(%{sentry: sentry_metadata})
  end

  defp set_context(key, new) when is_map(new) do
    sentry_metadata =
      case :logger.get_process_metadata() do
        %{sentry: sentry} -> Map.update(sentry, key, new, &Map.merge(&1, new))
        _ -> %{key => new}
      end

    :logger.update_process_metadata(%{sentry: sentry_metadata})
  end

  @doc """
  Returns the keys used to store context in the current Process's process
  dictionary.

  ## Example

      iex> Sentry.Context.context_keys()
      [:breadcrumbs, :tags, :user, :extra]
  """
  @spec context_keys() :: list(atom())
  def context_keys do
    [@breadcrumbs_key, @tags_key, @user_key, @extra_key]
  end
end
