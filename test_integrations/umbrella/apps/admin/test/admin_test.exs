defmodule Admin.Sentry.ConfigTest do
  use ExUnit.Case

  test "loads in_app_module_allow_list" do
    assert Sentry.Config.in_app_module_allow_list() |> Enum.sort() ==
             [Admin, Admin.Settings, Public, Public.User]
  end
end
