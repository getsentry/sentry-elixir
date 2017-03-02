defmodule Sentry.Context do
  @moduledoc """
  Provides a method to store user, tags, and extra context when an
  event is reported. The contexts will be fetched and merged into
  the event.

  Sentry.Context uses the Process Dictionary to store this state.
  This imposes some limitations. The state will only exist within
  the current process, and the context will die with the process.

  For example, if you add context inside your controller and an
  error happens in a Task the context won't send.
  """

  @process_dictionary_key :sentry_context
  @user_key :user
  @tags_key :tags
  @extra_key :extra
  @request_key :request
  @breadcrumbs_key :breadcrumbs

  @keys [{:user, @user_key},
         {:tags, @tags_key},
         {:extra, @extra_key},
         {:http, @request_key}]

  @type data :: keyword() | map()

  def get_all do
    context = get_context()

    for {_, key} <- @keys, into: %{} do
      {key, Map.get(context, key, %{})}
    end
    |> Map.put(@breadcrumbs_key, Enum.reverse(Map.get(context, :breadcrumbs, [])))
  end

  Enum.each @keys, fn {name, key} ->
    @spec unquote(:"set_#{name}_context")(data):: any()
    def unquote(:"set_#{name}_context")(map) do
      map
      |> Map.new
      |> set_context(unquote(key))
    end
  end

  def clear_all do
    Process.delete(@process_dictionary_key)
  end

  defp get_context do
    Process.get(@process_dictionary_key, %{})
  end

  @spec add_breadcrumb(data) :: any()
  def add_breadcrumb(map) do
    map = map
          |> Map.new
          |> Map.put_new(:timestamp, Sentry.Util.unix_timestamp())

    context = get_context()
              |> Map.update(@breadcrumbs_key, [map], &([map | &1]))

    Process.put(@process_dictionary_key, context)
  end

  def pop_breadcrumb do
    context = get_context()
              |> Map.update!(@breadcrumbs_key, fn [_ | tail] -> tail end)

    Process.put(@process_dictionary_key, context)
  end

  defp set_context(new, key) do
    context = get_context()
              |> Map.update(key, new, &Map.merge(&1, new))

    Process.put(@process_dictionary_key, context)
  end

  def context_keys do
    [@breadcrumbs_key, @tags_key, @user_key, @extra_key]
  end
end
