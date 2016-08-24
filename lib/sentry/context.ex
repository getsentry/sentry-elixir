defmodule Sentry.Context do
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

  defp get_context do
    Process.get(@process_dictionary_key) || %{}
  end

  defp set_context(current, key, new) when is_map(current) and is_map(new) do
    merged_context = Map.get(current, key, %{})
                      |> Map.merge(new)

    new_context = Map.put(current, key, merged_context)
    Process.put(@process_dictionary_key, new_context)
  end
end
