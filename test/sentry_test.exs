defmodule SentryTest do
  use ExUnit.Case, async: true
  test "fails with RuntimeError without environment_name configured" do
    assert_raise RuntimeError, fn ->
      Application.delete_env(:sentry, :environment_name)
      Sentry.start(nil, nil)
    end

    Application.put_env(:sentry, :environment_name, :test)
  end
end
