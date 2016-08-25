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
  @user_key :user_context
  @tags_key :tags_context
  @extra_key :extra_context

  def get_all do
    context = get_context()
    %{
      user: Map.get(context, @user_key, %{}),
      tags: Map.get(context, @tags_key, %{}),
      extra: Map.get(context, @extra_key, %{}),
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

  def clear_all do
    Process.delete(@process_dictionary_key)
  end

  defp get_context do
    Process.get(@process_dictionary_key) || %{}
  end

  defp set_context(current, key, new) when is_map(current) and is_map(new) do
    merged_context = current
                      |> Map.get(key, %{})
                      |> Map.merge(new)

    new_context = Map.put(current, key, merged_context)
    Process.put(@process_dictionary_key, new_context)
  end
end
