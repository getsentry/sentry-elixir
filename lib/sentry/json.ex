defmodule Sentry.JSON do
  @moduledoc false

  @default_library if(Code.ensure_loaded?(JSON), do: JSON, else: Jason)
  @library Application.compile_env(:sentry, :json_library, @default_library)

  @spec decode(String.t()) :: {:ok, term()} | {:error, term()}
  if @library == JSON do
    def decode(binary) do
      {:ok, JSON.decode!(binary)}
    rescue
      error -> {:error, error}
    end
  else
    defdelegate decode(binary), to: @library
  end

  @spec encode(term()) :: {:ok, String.t()} | {:error, term()}
  if @library == JSON do
    def encode(data) do
      {:ok, JSON.encode!(data)}
    rescue
      error -> {:error, error}
    end
  else
    defdelegate encode(data), to: @library
  end
end
