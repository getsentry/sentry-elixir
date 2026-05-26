defmodule Sentry.ScrubberTest do
  use ExUnit.Case, async: true

  alias Sentry.Scrubber

  describe "scrub_map/2" do
    test "redacts sensitive top-level keys" do
      assert Scrubber.scrub_map(%{"password" => "x", "ok" => 1}) ==
               %{"password" => "*********", "ok" => 1}
    end

    test "recurses into nested maps" do
      assert Scrubber.scrub_map(%{"outer" => %{"secret" => "shh"}}) ==
               %{"outer" => %{"secret" => "*********"}}
    end

    test "recurses into lists of maps" do
      assert Scrubber.scrub_map(%{"items" => [%{"passwd" => "1"}, %{"ok" => 2}]}) ==
               %{"items" => [%{"passwd" => "*********"}, %{"ok" => 2}]}
    end

    test "redacts credit-card-shaped values" do
      assert Scrubber.scrub_map(%{"cc" => "4111111111111111"}) ==
               %{"cc" => "*********"}
    end

    test "scrubs structs by converting them to maps" do
      uri = URI.parse("http://example.com")
      assert %{"u" => scrubbed} = Scrubber.scrub_map(%{"u" => uri})
      assert is_map(scrubbed)
      refute Map.has_key?(scrubbed, :__struct__)
    end

    test "respects custom :keys option" do
      assert Scrubber.scrub_map(%{"api_key" => "x", "password" => "y"}, keys: ["api_key"]) ==
               %{"api_key" => "*********", "password" => "y"}
    end

    test "leaves non-sensitive values untouched" do
      data = %{"name" => "alice", "age" => 30}
      assert Scrubber.scrub_map(data) == data
    end
  end

  describe "drop_keys/2" do
    test "drops sensitive header keys by default" do
      assert Scrubber.drop_keys(%{"authorization" => "Bearer x", "x-trace" => "1"}) ==
               %{"x-trace" => "1"}
    end

    test "respects custom :keys option" do
      assert Scrubber.drop_keys(%{"x-secret" => "1", "x-trace" => "1"}, keys: ["x-secret"]) ==
               %{"x-trace" => "1"}
    end
  end

  describe "scrub_url/2" do
    test "redacts sensitive query parameters" do
      url = "http://example.com/foo?password=secret&visible=ok"
      scrubbed = Scrubber.scrub_url(url)
      refute scrubbed =~ "secret"
      assert scrubbed =~ "visible=ok"
    end

    test "passes through URLs without query strings" do
      assert Scrubber.scrub_url("http://example.com/foo") == "http://example.com/foo"
    end

    test "preserves scheme, host, port, and path" do
      scrubbed = Scrubber.scrub_url("https://example.com:8443/p?secret=x")
      assert scrubbed =~ "https://example.com:8443/p?"
      refute scrubbed =~ "secret=x"
    end
  end

  describe "scrub_query_string/2" do
    test "redacts sensitive params" do
      scrubbed = Scrubber.scrub_query_string("password=hunter2&visible=ok")
      refute scrubbed =~ "hunter2"
      assert scrubbed =~ "visible=ok"
    end
  end

  describe "scrub_conn/1 with no registered scrubber" do
    setup do
      conn = %Plug.Conn{
        cookies: %{"session" => "secret-session"},
        req_headers: [
          {"Authorization", "Bearer secret-token"},
          {"cookie", "session=secret-session"},
          {"x-request-id", "abc-123"}
        ],
        params: %{"password" => "hunter2", "name" => "Alice"}
      }

      %{conn: conn, scrubbed: Scrubber.scrub_conn(conn)}
    end

    test "clears cookies", %{scrubbed: scrubbed} do
      assert scrubbed.cookies == %{}
    end

    test "drops sensitive req_headers case-insensitively and keeps list shape",
         %{scrubbed: scrubbed} do
      assert scrubbed.req_headers == [{"x-request-id", "abc-123"}]
      assert is_list(scrubbed.req_headers)
    end

    test "scrubs params", %{scrubbed: scrubbed} do
      assert scrubbed.params == %{"password" => "*********", "name" => "Alice"}
    end

    test "returns a %Plug.Conn{} struct", %{scrubbed: scrubbed} do
      assert is_struct(scrubbed, Plug.Conn)
    end
  end

  describe "put_conn_scrubber/1 + scrub_conn/1" do
    defmodule MarkerScrubber do
      def stamp(conn, marker) do
        %{conn | params: %{"marker" => marker}}
      end
    end

    test "registered MFA scrubber wins over the default" do
      conn = %Plug.Conn{params: %{"password" => "hunter2"}}

      :ok = Scrubber.put_conn_scrubber({MarkerScrubber, :stamp, ["registered"]})

      scrubbed = Scrubber.scrub_conn(conn)
      assert scrubbed.params == %{"marker" => "registered"}
    end

    test "registration is process-local" do
      conn = %Plug.Conn{params: %{"password" => "hunter2"}}

      task =
        Task.async(fn ->
          :ok = Scrubber.put_conn_scrubber({MarkerScrubber, :stamp, ["task-only"]})
          Scrubber.scrub_conn(conn)
        end)

      task_result = Task.await(task)
      assert task_result.params == %{"marker" => "task-only"}

      # The current process never registered a scrubber, so it falls back to the default.
      scrubbed = Scrubber.scrub_conn(conn)
      assert scrubbed.params == %{"password" => "*********"}
    end

    test "raises when the registered scrubber returns a non-Plug.Conn" do
      defmodule BrokenScrubber do
        def scrub(_conn), do: :not_a_conn
      end

      conn = %Plug.Conn{}
      :ok = Scrubber.put_conn_scrubber({BrokenScrubber, :scrub, []})

      assert_raise RuntimeError, ~r/expected.*to return a Plug.Conn/, fn ->
        Scrubber.scrub_conn(conn)
      end
    end

    test "validates the MFA shape on put" do
      assert_raise FunctionClauseError, fn ->
        Scrubber.put_conn_scrubber({"not", "an", "mfa"})
      end
    end
  end
end
