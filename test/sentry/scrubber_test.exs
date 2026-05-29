defmodule Sentry.ScrubberTest do
  use ExUnit.Case, async: true

  alias Sentry.Scrubber

  describe "new/1" do
    test "new/0 builds an all-defaults scrubber" do
      scrubber = Scrubber.new()

      assert %Scrubber{} = scrubber

      for field <- Scrubber.scrubber_names() do
        assert is_function(Map.fetch!(scrubber, field), 1)
      end
    end

    test "uses the given per-field scrubber and defaults the rest" do
      marker = fn _conn -> %{"marker" => "custom"} end
      scrubber = Scrubber.new(body_scrubber: marker)

      assert scrubber.body_scrubber == marker
      assert is_function(scrubber.header_scrubber, 1)
    end

    test "does not register the scrubber for the process" do
      _ = Scrubber.new(body_scrubber: fn _conn -> %{"marker" => "unregistered"} end)

      conn = %Plug.Conn{params: %{"password" => "hunter2"}}
      assert Scrubber.scrub(conn).params == %{"password" => "*********"}
    end
  end

  describe "scrub/2" do
    test "redacts sensitive top-level keys" do
      assert Scrubber.scrub(%{"password" => "x", "ok" => 1}) ==
               %{"password" => "*********", "ok" => 1}
    end

    test "recurses into nested maps" do
      assert Scrubber.scrub(%{"outer" => %{"secret" => "shh"}}) ==
               %{"outer" => %{"secret" => "*********"}}
    end

    test "recurses into lists of maps" do
      assert Scrubber.scrub(%{"items" => [%{"passwd" => "1"}, %{"ok" => 2}]}) ==
               %{"items" => [%{"passwd" => "*********"}, %{"ok" => 2}]}
    end

    test "redacts credit-card-shaped values" do
      assert Scrubber.scrub(%{"cc" => "4111111111111111"}) ==
               %{"cc" => "*********"}
    end

    test "scrubs structs by converting them to maps" do
      uri = URI.parse("http://example.com")
      assert %{"u" => scrubbed} = Scrubber.scrub(%{"u" => uri})
      assert is_map(scrubbed)
      refute Map.has_key?(scrubbed, :__struct__)
    end

    test "respects custom :keys option" do
      assert Scrubber.scrub(%{"api_key" => "x", "password" => "y"}, keys: ["api_key"]) ==
               %{"api_key" => "*********", "password" => "y"}
    end

    test "leaves non-sensitive values untouched" do
      data = %{"name" => "alice", "age" => 30}
      assert Scrubber.scrub(data) == data
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

  describe "scrub/2 with a Plug.Conn field" do
    test ":url returns the request URL unchanged, including sensitive query params" do
      conn = %Plug.Conn{
        scheme: :http,
        host: "example.com",
        port: 80,
        request_path: "/foo",
        query_string: "password=secret&visible=ok"
      }

      assert Scrubber.scrub(conn, :url) == Plug.Conn.request_url(conn)
      assert Scrubber.scrub(conn, :url) =~ "password=secret"
    end
  end

  describe "scrub_query_string/2" do
    test "redacts sensitive params" do
      scrubbed = Scrubber.scrub_query_string("password=hunter2&visible=ok")
      refute scrubbed =~ "hunter2"
      assert scrubbed =~ "visible=ok"
    end
  end

  describe "scrub/1 with no registered scrubber" do
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

      %{conn: conn, scrubbed: Scrubber.scrub(conn)}
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

    test "rewrites only cookies, req_headers, and params", %{conn: conn, scrubbed: scrubbed} do
      changed =
        conn
        |> Map.from_struct()
        |> Enum.filter(fn {key, value} -> Map.fetch!(scrubbed, key) != value end)
        |> Enum.map(fn {key, _value} -> key end)
        |> Enum.sort()

      assert changed == [:cookies, :params, :req_headers]
    end
  end

  describe "put_conn_scrubber/1 + scrub/1" do
    test "registered :body_scrubber wins over the default" do
      conn = %Plug.Conn{params: %{"password" => "hunter2"}}

      :ok = Scrubber.put_conn_scrubber(body_scrubber: fn _ -> %{"marker" => "registered"} end)

      scrubbed = Scrubber.scrub(conn)
      assert scrubbed.params == %{"marker" => "registered"}
    end

    test "a map-returning :header_scrubber still yields list-shaped req_headers" do
      conn = %Plug.Conn{req_headers: [{"authorization", "Bearer x"}, {"x-keep", "yes"}]}

      :ok =
        Scrubber.put_conn_scrubber(
          header_scrubber: fn conn -> conn.req_headers |> Map.new() |> Map.take(["x-keep"]) end
        )

      scrubbed = Scrubber.scrub(conn)
      assert is_list(scrubbed.req_headers)
      assert scrubbed.req_headers == [{"x-keep", "yes"}]
    end

    test "registered {module, function} tuple is invoked with the conn" do
      defmodule TupleScrubber do
        def stamp(_conn), do: %{"marker" => "from-mf"}
      end

      conn = %Plug.Conn{params: %{"password" => "hunter2"}}
      :ok = Scrubber.put_conn_scrubber(body_scrubber: {TupleScrubber, :stamp})

      assert Scrubber.scrub(conn).params == %{"marker" => "from-mf"}
    end

    test "a nil scrubber for a field clears that field to %{}" do
      conn = %Plug.Conn{
        cookies: %{"session" => "secret"},
        req_headers: [{"authorization", "Bearer x"}],
        params: %{"password" => "hunter2"}
      }

      :ok = Scrubber.put_conn_scrubber(body_scrubber: nil, cookie_scrubber: nil)

      scrubbed = Scrubber.scrub(conn)
      assert scrubbed.params == %{}
      assert scrubbed.cookies == %{}
    end

    test "missing keys fall back to Sentry.PlugContext defaults" do
      conn = %Plug.Conn{
        cookies: %{"session" => "secret"},
        req_headers: [{"authorization", "Bearer x"}, {"x-keep", "yes"}],
        params: %{"password" => "hunter2", "name" => "Alice"}
      }

      :ok = Scrubber.put_conn_scrubber([])

      scrubbed = Scrubber.scrub(conn)
      assert scrubbed.cookies == %{}
      assert scrubbed.params == %{"password" => "*********", "name" => "Alice"}
      assert is_list(scrubbed.req_headers)
      assert {"x-keep", "yes"} in scrubbed.req_headers
      refute Enum.any?(scrubbed.req_headers, fn {k, _v} -> k == "authorization" end)
    end

    test "registration is process-local" do
      conn = %Plug.Conn{params: %{"password" => "hunter2"}}

      task =
        Task.async(fn ->
          :ok = Scrubber.put_conn_scrubber(body_scrubber: fn _ -> %{"marker" => "task-only"} end)
          Scrubber.scrub(conn)
        end)

      task_result = Task.await(task)
      assert task_result.params == %{"marker" => "task-only"}

      # The current process never registered a scrubber, so scrub/1 lazily
      # initializes defaults instead of inheriting the task's marker scrubber.
      scrubbed = Scrubber.scrub(conn)
      assert scrubbed.params == %{"password" => "*********"}
    end

    test "validates the opts shape on put" do
      assert_raise FunctionClauseError, fn ->
        Scrubber.put_conn_scrubber({"not", "an", "mfa"})
      end
    end
  end

  describe "scrub/1 dispatch" do
    test "delegates Plug.Conn input to the conn scrubbers" do
      conn = %Plug.Conn{
        cookies: %{"session" => "secret"},
        req_headers: [{"authorization", "Bearer x"}, {"x-keep", "yes"}],
        params: %{"password" => "hunter2"}
      }

      scrubbed = Scrubber.scrub(conn)

      assert is_struct(scrubbed, Plug.Conn)
      assert scrubbed.cookies == %{}
      assert scrubbed.req_headers == [{"x-keep", "yes"}]
      assert scrubbed.params == %{"password" => "*********"}
    end

    test "honors a registered conn scrubber for the Plug.Conn dispatch path" do
      defmodule ScrubValueMarkerScrubber do
        def stamp(_conn), do: %{"marker" => "from-registered"}
      end

      :ok = Scrubber.put_conn_scrubber(body_scrubber: {ScrubValueMarkerScrubber, :stamp})

      scrubbed = Scrubber.scrub(%Plug.Conn{params: %{"password" => "hunter2"}})

      assert scrubbed.params == %{"marker" => "from-registered"}
    end

    test "scrubs a plain map with default sensitive keys" do
      assert Scrubber.scrub(%{"password" => "x", "ok" => 1}) ==
               %{"password" => "*********", "ok" => 1}
    end

    test "returns integers, atoms, binaries, and lists unchanged" do
      assert Scrubber.scrub(42) == 42
      assert Scrubber.scrub(:foo) == :foo
      assert Scrubber.scrub("hello") == "hello"
      assert Scrubber.scrub([1, 2, 3]) == [1, 2, 3]
    end

    test "returns unrelated structs unchanged" do
      uri = URI.parse("http://example.com")
      assert Scrubber.scrub(uri) == uri
    end
  end
end
