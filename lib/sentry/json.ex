defmodule Sentry.JSON do
  @moduledoc false

  @spec encode(term(), module()) :: {:ok, String.t()} | {:error, term()}
  def encode(data, json_library)

  if Code.ensure_loaded?(JSON) do
    def encode(data, JSON) do
      {:ok, JSON.encode!(data)}
    rescue
      error -> {:error, error}
    end
  end

  def encode(data, json_library) do
    json_library.encode(data)
  end

  @spec decode(binary(), module()) :: {:ok, term()} | {:error, term()}
  def decode(binary, json_library)

  if Code.ensure_loaded?(JSON) do
    def decode(binary, JSON) do
      {:ok, JSON.decode!(binary)}
    rescue
      error -> {:error, error}
    end
  end

  def decode(binary, json_library) do
    json_library.decode(binary)
  end
end
