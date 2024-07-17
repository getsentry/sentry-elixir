defmodule Sentry.Mapping do
  @moduledoc false

  def new() do
    :ets.new(:cron, [:named_table, :set, :public, read_concurrency: true])
  end

  def insert(table, key, value) do
    :ets.insert(table, {key, value})

    {:ok, value}
  end

  def lookup(table, key) do
    case :ets.lookup(table, key) do
      [{^key, value}] ->
        {:ok, value}

      [] ->
        :error
    end
  end
end
