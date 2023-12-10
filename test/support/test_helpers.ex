defmodule Sentry.TestHelpers do
  import ExUnit.Assertions

  alias Sentry.Config

  @spec put_test_config(keyword()) :: :ok
  def put_test_config(config) when is_list(config) do
    all_original_config = all_config()

    original_config =
      for {key, val} <- config do
        renamed_key =
          case key do
            :before_send_event -> :before_send
            other -> other
          end

        current_val = :persistent_term.get({:sentry_config, renamed_key}, :__not_set__)
        Sentry.put_config(renamed_key, val)
        {renamed_key, current_val}
      end

    ExUnit.Callbacks.on_exit(fn ->
      Enum.each(original_config, fn
        {key, :__not_set__} -> :persistent_term.erase({:sentry_config, key})
        {key, original_val} -> :persistent_term.put({:sentry_config, key}, original_val)
      end)

      assert all_original_config == all_config()
    end)
  end

  @spec set_mix_shell(module()) :: :ok
  def set_mix_shell(shell) do
    mix_shell = Mix.shell()
    ExUnit.Callbacks.on_exit(fn -> Mix.shell(mix_shell) end)
    Mix.shell(shell)
    :ok
  end

  @spec all_config() :: keyword()
  def all_config do
    Enum.sort(for {{:sentry_config, key}, value} <- :persistent_term.get(), do: {key, value})
  end

  @spec decode_envelope!(binary()) :: [{header :: map(), item :: map()}]
  def decode_envelope!(binary) do
    [id_line | rest] = String.split(binary, "\n")
    {:ok, %{"event_id" => _}} = Config.json_library().decode(id_line)
    decode_envelope_items(rest)
  end

  defp decode_envelope_items(items) do
    items
    |> Enum.chunk_every(2)
    |> Enum.flat_map(fn
      [header, item] ->
        {:ok, header} = Config.json_library().decode(header)
        {:ok, item} = Config.json_library().decode(item)
        [{header, item}]

      [""] ->
        []
    end)
  end
end
