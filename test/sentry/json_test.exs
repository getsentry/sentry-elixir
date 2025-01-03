defmodule Sentry.JSONTest do
  use ExUnit.Case, async: true

  json_modules =
    if Code.ensure_loaded?(JSON) do
      [JSON, Jason]
    else
      [Jason]
    end

  for json_mod <- json_modules do
    describe "decode/2 with #{inspect(json_mod)}" do
      test "decodes empty object to empty map" do
        assert Sentry.JSON.decode("{}", unquote(json_mod)) == {:ok, %{}}
      end

      test "returns {:error, reason} if binary is not a JSON" do
        assert {:error, _reason} = Sentry.JSON.decode("not JSON", unquote(json_mod))
      end
    end

    describe "encode/2 with #{inspect(json_mod)}" do
      test "encodes empty map to empty object" do
        assert Sentry.JSON.encode(%{}, unquote(json_mod)) == {:ok, "{}"}
      end

      test "returns {:error, reason} if data cannot be parsed to JSON" do
        assert {:error, _reason} = Sentry.JSON.encode({:ok, "will fail"}, unquote(json_mod))
      end
    end
  end
end
