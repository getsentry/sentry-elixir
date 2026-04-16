defmodule Sentry.Test.RegistryTest do
  use Sentry.Case, async: false

  import ExUnit.CaptureLog

  alias Sentry.Test.Registry

  describe "maybe_warn_about_dsn_override/1" do
    test "warns when a DSN is already configured" do
      Sentry.put_config(:dsn, "http://public:secret@example.com/1")
      on_exit(fn -> Sentry.put_config(:dsn, nil) end)

      log =
        capture_log(fn ->
          Registry.maybe_warn_about_dsn_override("http://public:secret@localhost:4000/1")
        end)

      assert log =~ "test_mode is enabled but a DSN was already configured"
      assert log =~ "example.com"
      assert log =~ "localhost:4000"
    end

    test "stays silent when no DSN is configured" do
      Sentry.put_config(:dsn, nil)

      log =
        capture_log(fn ->
          Registry.maybe_warn_about_dsn_override("http://public:secret@localhost:4000/1")
        end)

      assert log == ""
    end
  end
end
