defmodule Sentry.Context do
  @moduledoc """
  Provides functionality to store user, tags, extra, and breadcrumbs context when an
  event is reported.

  The contexts will be fetched and merged into the event when it is sent.

  `Sentry.Context` uses Elixir `Logger` metadata to store the context itself.
  This imposes some limitations. The metadata will only exist **within
  the current process**, and the context will disappear when the process
  dies. For example, if you add context inside your controller and an
  error happens in a spawned `Task`, that context will not be included.

  A common use case is to set context when handling requests within Plug or Phoenix
  applications, as each request is its own process, and so any stored context is included
  should an error be reported within that request process. For example:

      # post_controller.ex
      def index(conn, _params) do
        Sentry.Context.set_user_context(%{id: conn.assigns.user_id})
        posts = Blog.list_posts()
        render(conn, "index.html", posts: posts)
      end

  > #### Merging {: .info}
  >
  > The `set_*_context/1` functions **merge** with the
  > existing context rather than entirely overwriting it.

  ## Sentry Documentation

  Sentry itself documents the meaning of the various contexts:

    * [General context interface](https://develop.sentry.dev/sdk/event-payloads/contexts/)
    * [Breadcrumbs interface](https://develop.sentry.dev/sdk/event-payloads/breadcrumbs/)
    * [Request context](https://develop.sentry.dev/sdk/event-payloads/request/)
    * [User context](https://develop.sentry.dev/sdk/event-payloads/user/)

  """

  alias Sentry.Interfaces

  @typedoc """
  User context.

  See `set_user_context/1`.

  You can use `"{{auto}}"` as the value of `:ip_address` to let Sentry infer the
  IP address (see [the documentation for automatic IP
  addresses](https://develop.sentry.dev/sdk/event-payloads/user/#automatic-ip-addresses)).

  Other than the keys specified in the typespec below, all other keys are stored
  as extra information but not specifically processed by Sentry.

  ## Example

      %{
        user: %{
          id: "unique_id",
          username: "my_user",
          email: "foo@example.com",
          ip_address: "127.0.0.1",

          # Extra key
          subscription: "basic"
        }
      }

  """
  @typedoc since: "9.0.0"
  @type user_context() :: %{
          optional(:id) => term(),
          optional(:username) => String.t(),
          optional(:email) => String.t(),
          optional(:ip_address) => term(),
          optional(:segment) => term(),
          optional(:geo) => %{
            optional(:city) => String.t(),
            optional(:country_code) => String.t(),
            optional(:region) => String.t()
          },
          optional(atom()) => term()
        }

  @typedoc """
  Breadcrumb info.

  See `add_breadcrumb/1`.

  All the atom keys in this map can also be specified as strings.

  ## Example

      %{
        type: "default",
        category: "ui.click",
        data: nil,
        level: "info",
        message: "User clicked on the main button",
        timestamp: 1596814007.035
      }

  """
  @typedoc since: "9.0.0"
  @type breadcrumb() :: %{
          optional(:type) => :default | :debug | :error | :navigation | String.t(),
          optional(:category) => String.t(),
          optional(:message) => String.t(),
          optional(:data) => map(),
          optional(:level) => :fatal | :error | :warning | :info | :debug,
          optional(:timestamp) => String.t() | integer(),
          optional(atom()) => term()
        }

  @typedoc """
  A map of **tags**.

  See `set_tags_context/1`.
  """
  @typedoc since: "9.0.0"
  @type tags() :: %{optional(atom()) => term()}

  @typedoc """
  A map of **extra** data.

  See `set_extra_context/1`.
  """
  @typedoc since: "9.0.0"
  @type extra() :: %{optional(atom()) => term()}

  @logger_metadata_key :sentry
  @user_key :user
  @tags_key :tags
  @extra_key :extra
  @request_key :request
  @breadcrumbs_key :breadcrumbs

  @doc """
  Retrieves all currently-set context on the current process.

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
          user: user_context(),
          tags: tags(),
          extra: extra(),
          request: Interfaces.request(),
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
  @spec set_extra_context(extra()) :: :ok
  def set_extra_context(map) when is_map(map) do
    set_context(@extra_key, map)
  end

  @doc """
  Merges new fields into the `:user` context, specific to the current process.

  This is used to set certain fields which identify the actor who experienced a
  specific instance of an error.

  The user context is documented [in the Sentry
  documentation](https://develop.sentry.dev/sdk/event-payloads/user/).

  > #### Additional Keys {: .error}
  >
  > While at least one of the keys described in `t:Sentry.Interfaces.user/0` is
  > recommended, you can also add any arbitrary key to the user context.

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
  @spec set_user_context(Interfaces.user()) :: :ok
  def set_user_context(user_context) when is_map(user_context) do
    set_context(@user_key, user_context)
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
  @spec set_tags_context(tags()) :: :ok
  def set_tags_context(map) when is_map(map) do
    set_context(@tags_key, map)
  end

  @doc """
  Merges new fields into the `:request` context, specific to the current
  process.

  This is used to set metadata that identifies the request associated with a
  specific instance of an error.

  The request context is documented [in the Sentry
  documentation](https://develop.sentry.dev/sdk/event-payloads/request/).

  > #### Invalid Keys {: .error}
  >
  > While this function accepts any map with atom keys, the only keys that
  > are valid are those in `t:Sentry.Interfaces.request/0`. We don't validate
  > keys because of performance concerns, so it's up to you to ensure that
  > you're passing valid keys.

  ## Example

      iex> Sentry.Context.set_request_context(%{url: "example.com"})
      :ok
      iex> headers = %{"accept" => "application/json"}
      iex> Sentry.Context.set_request_context(%{headers: headers, method: "GET"})
      :ok
      iex> Sentry.Context.get_all()
      %{
          breadcrumbs: [],
          extra: %{},
          request: %{method: "GET", headers: %{"accept" => "application/json"}, url: "example.com"},
          tags: %{},
          user: %{}
      }

  """
  @spec set_request_context(Interfaces.request()) :: :ok
  def set_request_context(request_context) when is_map(request_context) do
    set_context(@request_key, request_context)
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
  @spec clear_all() :: :ok
  def clear_all do
    :logger.update_process_metadata(%{@logger_metadata_key => %{}})
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

  See the [Sentry documentation](https://develop.sentry.dev/sdk/event-payloads/breadcrumbs/)
  for more information.

  If `breadcrumb_info` is a keyword list, it should be convertable to a map of type
  `t:breadcrumb/0`.

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
  @spec add_breadcrumb(keyword() | breadcrumb()) :: :ok
  def add_breadcrumb(breadcrumb_info)

  def add_breadcrumb(list) when is_list(list) do
    if Keyword.keyword?(list) do
      list
      |> Map.new()
      |> add_breadcrumb()
    else
      raise ArgumentError, """
      Sentry.Context.add_breadcrumb/1 only accepts keyword lists or maps, \
      got a non-keyword list: #{inspect(list)}\
      """
    end
  end

  def add_breadcrumb(map) when is_map(map) do
    map = Map.put_new(map, :timestamp, System.system_time(:second))

    sentry_metadata =
      get_sentry_context()
      |> Map.update(@breadcrumbs_key, [map], fn breadcrumbs ->
        breadcrumbs = [map | breadcrumbs]
        Enum.take(breadcrumbs, -1 * Sentry.Config.max_breadcrumbs())
      end)

    :logger.update_process_metadata(%{@logger_metadata_key => sentry_metadata})
  end

  defp set_context(key, new) when is_map(new) do
    sentry_metadata =
      case :logger.get_process_metadata() do
        %{@logger_metadata_key => sentry} -> Map.update(sentry, key, new, &Map.merge(&1, new))
        _ -> %{key => new}
      end

    :logger.update_process_metadata(%{@logger_metadata_key => sentry_metadata})
  end

  @doc """
  Returns the keys used to store context in the current process' logger metadata.

  ## Example

      iex> Sentry.Context.context_keys()
      [:breadcrumbs, :tags, :user, :extra, :request]

  """
  @spec context_keys() :: [atom(), ...]
  def context_keys do
    [@breadcrumbs_key, @tags_key, @user_key, @extra_key, @request_key]
  end
end
