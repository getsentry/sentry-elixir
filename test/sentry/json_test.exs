defmodule Sentry.JSONTest do
  use ExUnit.Case, async: true

  describe "decode/1" do
    test "decodes empty object to empty map" do
      assert Sentry.JSON.decode("{}") == {:ok, %{}}
    end

    test "returns {:error, reason} if binary is not a JSON" do
      assert {:error, _reason} = Sentry.JSON.decode("not JSON")
    end
  end

  describe "encode/1" do
    test "encodes empty map to empty object" do
      assert Sentry.JSON.encode(%{}) == {:ok, "{}"}
    end

    test "returns {:error, reason} if data cannot be parsed to JSON" do
      assert {:error, _reason} = Sentry.JSON.encode({:ok, "will fail"})
    end
  end
end
