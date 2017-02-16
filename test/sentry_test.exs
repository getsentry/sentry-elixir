defmodule SentryTest do
  use ExUnit.Case

  alias Sentry.Event

  setup do
    bypass = Bypass.open

    Application.put_env(:sentry, :filter, Sentry.TestFilter)
    Application.put_env(:sentry, :dsn, "http://public:secret@localhost:#{bypass.port}/1")
    Application.put_env(:sentry, :included_environments, [:test])
    Application.put_env(:sentry, :environment_name, :test)

    {:ok, bypass: bypass}
  end

  @opts event_source: :plug
  @error %RuntimeError{message: "error"}
  @excluded %ArithmeticError{message: "error"}

  describe "Sentry.capture_exception/2" do
    test "returns :ok on success", %{bypass: bypass} do
      expect_request(bypass)

      assert {:ok, %Event{}, %Task{}} = Sentry.capture_exception(@error, @opts)
    end

    test "returns :excluded on excluded exception" do
      assert :excluded = Sentry.capture_exception(@excluded, @opts)
    end
  end

  describe "Sentry.capture_message/2" do
    test "returns :ok on success", %{bypass: bypass} do
      expect_request(bypass)

      assert {:ok, %Event{}, %Task{}} = Sentry.capture_message("RuntimeError: error", @opts)
    end
  end

  defp expect_request(bypass) do
    Bypass.expect(bypass, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      assert body =~ "RuntimeError"
      assert conn.request_path == "/api/1/store/"
      assert conn.method == "POST"

      Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
    end)
  end
end
