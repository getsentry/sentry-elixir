defmodule Sentry.ScrubberTest.LeakyStruct do
  @moduledoc false
  defstruct [:card_number, :name]
end

defmodule Sentry.ScrubberTest do
  use ExUnit.Case, async: true

  alias Sentry.Scrubber
  alias Sentry.ScrubberTest.LeakyStruct

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

    test "redacts sensitive keys given as atoms (e.g. struct fields)" do
      assert Scrubber.scrub(%{password: "x", ok: 1}) ==
               %{password: "*********", ok: 1}
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
    test ":url scrubs sensitive query parameters" do
      conn = %Plug.Conn{
        scheme: :http,
        host: "example.com",
        port: 80,
        request_path: "/foo",
        query_string: "password=secret&visible=ok"
      }

      scrubbed = Scrubber.scrub(conn, :url)

      refute scrubbed =~ "secret"
      assert scrubbed =~ "visible=ok"
      assert scrubbed =~ "http://example.com/foo?"
      # equivalent to scrubbing the URL directly
      assert scrubbed == Scrubber.scrub_url(Plug.Conn.request_url(conn))
    end

    test "a nil :url_scrubber leaves the URL unchanged" do
      conn = %Plug.Conn{
        scheme: :http,
        host: "example.com",
        port: 80,
        request_path: "/foo",
        query_string: "password=secret&visible=ok"
      }

      :ok = Scrubber.put_conn_scrubber(url_scrubber: nil)

      assert Scrubber.get(:url_scrubber).(conn) == Plug.Conn.request_url(conn)
      assert Scrubber.get(:url_scrubber).(conn) =~ "password=secret"
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
        # `Plug.Conn.fetch_cookies/2` parses incoming Cookie headers into both
        # `cookies` and `req_cookies`. Apps using Plug.Session also see the
        # encoded session cookie here.
        cookies: %{
          "_my_app_session" => "SFMyNTY.g3QAAAACbQAAAAtfY3Nyb..."
        },
        req_cookies: %{
          "_my_app_session" => "SFMyNTY.g3QAAAACbQAAAAtfY3Nyb...",
          "user_remember_me" => "abc123-remember-token"
        },
        req_headers: [
          {"authorization", "Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.signature"},
          {"cookie", "_my_app_session=...; user_remember_me=abc123"},
          {"x-request-id", "req-abc-123"}
        ],
        params: %{
          "user" => %{"email" => "alice@example.com", "password" => "hunter2"},
          "_csrf_token" => "csrf-leaky-token"
        },
        body_params: %{
          "user" => %{"email" => "alice@example.com", "password" => "hunter2"}
        },
        query_params: %{
          "redirect_to" => "/dashboard",
          "secret" => "password-reset-token-xyz"
        },
        # Guardian.Plug.LoadResource and custom auth plugs put the loaded user
        # struct here. Pow uses conn.assigns[:current_user] by default.
        assigns: %{
          current_user: %{
            id: 1,
            email: "alice@example.com",
            password_hash: "$2b$12$leaky.bcrypt.hash.value.here"
          },
          jwt_claims: %{"sub" => "1", "exp" => 1_700_000_000, "secret" => "claim-secret"}
        },
        # Guardian stores the raw JWT and decoded claims here. Plug.Session
        # puts the session data here. Phoenix populates its own routing /
        # dispatch metadata here.
        private: %{
          guardian_default_token: "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.signature",
          guardian_default_claims: %{"sub" => "1", "exp" => 1_700_000_000},
          plug_session: %{"user_id" => 1, "_csrf_token" => "csrf-token-xyz"},
          phoenix_endpoint: SomeApp.Endpoint,
          phoenix_controller: SomeApp.PageController
        },
        request_path: "/users",
        method: "POST"
      }

      %{conn: conn, scrubbed: Scrubber.scrub(conn)}
    end

    test "clears cookies and req_cookies", %{scrubbed: scrubbed} do
      assert scrubbed.cookies == %{}
      assert scrubbed.req_cookies == %{}
    end

    test "drops sensitive req_headers case-insensitively and keeps list shape",
         %{scrubbed: scrubbed} do
      assert scrubbed.req_headers == [{"x-request-id", "req-abc-123"}]
      assert is_list(scrubbed.req_headers)
    end

    test "scrubs params with default sensitive keys", %{scrubbed: scrubbed} do
      assert scrubbed.params == %{
               "user" => %{"email" => "alice@example.com", "password" => "*********"},
               "_csrf_token" => "csrf-leaky-token"
             }
    end

    test "scrubs body_params with default sensitive keys", %{scrubbed: scrubbed} do
      assert scrubbed.body_params == %{
               "user" => %{"email" => "alice@example.com", "password" => "*********"}
             }
    end

    test "scrubs query_params with default sensitive keys", %{scrubbed: scrubbed} do
      assert scrubbed.query_params == %{
               "redirect_to" => "/dashboard",
               "secret" => "*********"
             }
    end

    test "clears assigns wholesale", %{scrubbed: scrubbed} do
      # Auth libraries put current_user + password_hash + JWT claims here.
      # No reliable key-based heuristic — clear the whole map.
      assert scrubbed.assigns == %{}
    end

    test "reduces private to the allow-listed framework metadata", %{scrubbed: scrubbed} do
      # Phoenix routing metadata is retained (high-signal for triage); Guardian
      # tokens and the decoded Plug.Session payload are dropped.
      assert scrubbed.private == %{
               phoenix_endpoint: SomeApp.Endpoint,
               phoenix_controller: SomeApp.PageController
             }

      refute Map.has_key?(scrubbed.private, :plug_session)
      refute Map.has_key?(scrubbed.private, :guardian_default_token)
      refute Map.has_key?(scrubbed.private, :guardian_default_claims)
    end

    test "preserves non-sensitive fields", %{scrubbed: scrubbed} do
      assert scrubbed.request_path == "/users"
      assert scrubbed.method == "POST"
    end

    test "returns a %Plug.Conn{} struct", %{scrubbed: scrubbed} do
      assert is_struct(scrubbed, Plug.Conn)
    end

    test "leaves %Plug.Conn.Unfetched{} body_params/query_params alone" do
      conn = %Plug.Conn{
        body_params: %Plug.Conn.Unfetched{aspect: :body_params},
        query_params: %Plug.Conn.Unfetched{aspect: :query_params}
      }

      scrubbed = Scrubber.scrub(conn)

      assert scrubbed.body_params == %Plug.Conn.Unfetched{aspect: :body_params}
      assert scrubbed.query_params == %Plug.Conn.Unfetched{aspect: :query_params}
    end

    test "scrubs sensitive params from query_string" do
      conn = %Plug.Conn{
        query_string: "password=secret&token=abc&card=4242424242424242&keep=ok"
      }

      scrubbed = Scrubber.scrub(conn).query_string

      refute scrubbed =~ "secret"
      refute scrubbed =~ "4242424242424242"
      assert scrubbed =~ "token=abc"
      assert scrubbed =~ "keep=ok"
    end
  end

  describe "scrub/2 with conn field overrides" do
    test ":clear override replaces additional fields with %{}" do
      conn = %Plug.Conn{
        params: %{"password" => "hunter2"},
        assigns: %{current_user: %{password_hash: "secret"}},
        private: %{guardian_token: "jwt"}
      }

      scrubbed = Scrubber.scrub(conn, assigns: :clear, private: :clear)

      # default fields still scrubbed
      assert scrubbed.params == %{"password" => "*********"}
      # overridden fields cleared wholesale
      assert scrubbed.assigns == %{}
      assert scrubbed.private == %{}
    end

    test ":params override scrubs the named field by default sensitive keys" do
      conn = %Plug.Conn{
        body_params: %{"user" => %{"password" => "hunter2", "email" => "a@b.c"}},
        query_params: %{"secret" => "leak", "page" => "1"}
      }

      scrubbed = Scrubber.scrub(conn, body_params: :params, query_params: :params)

      assert scrubbed.body_params == %{
               "user" => %{"password" => "*********", "email" => "a@b.c"}
             }

      assert scrubbed.query_params == %{"secret" => "*********", "page" => "1"}
    end

    test ":params override leaves %Plug.Conn.Unfetched{} untouched" do
      unfetched = %Plug.Conn.Unfetched{aspect: :body_params}
      conn = %Plug.Conn{body_params: unfetched}

      scrubbed = Scrubber.scrub(conn, body_params: :params)

      assert scrubbed.body_params == unfetched
    end

    test "an override can change a default field's strategy" do
      conn = %Plug.Conn{params: %{"password" => "hunter2", "name" => "Alice"}}

      # default for :params is :body_scrubber (key-based); override to :clear
      scrubbed = Scrubber.scrub(conn, params: :clear)

      assert scrubbed.params == %{}
    end

    test "no overrides behaves like scrub/1" do
      conn = %Plug.Conn{
        cookies: %{"session" => "secret"},
        params: %{"password" => "hunter2"}
      }

      assert Scrubber.scrub(conn, []) == Scrubber.scrub(conn)
    end
  end

  describe ":private_allow_list strategy" do
    setup do
      conn = %Plug.Conn{
        private: %{
          phoenix_controller: SomeApp.PageController,
          phoenix_action: :show,
          phoenix_endpoint: SomeApp.Endpoint,
          phoenix_router: SomeApp.Router,
          plug_session: %{"user_id" => 1, "token" => "secret"},
          guardian_default_token: "eyJhbG.signature"
        }
      }

      %{conn: conn}
    end

    test "keeps default-allow-listed routing keys and drops everything else", %{conn: conn} do
      scrubbed = Scrubber.scrub(conn, private: :private_allow_list)

      assert scrubbed.private == %{
               phoenix_controller: SomeApp.PageController,
               phoenix_action: :show,
               phoenix_endpoint: SomeApp.Endpoint,
               phoenix_router: SomeApp.Router
             }

      refute Map.has_key?(scrubbed.private, :plug_session)
      refute Map.has_key?(scrubbed.private, :guardian_default_token)
    end

    test "honors a custom private_allow_list registered via put_conn_scrubber/1", %{conn: conn} do
      :ok = Scrubber.put_conn_scrubber(private_allow_list: [:phoenix_action])

      scrubbed = Scrubber.scrub(conn, private: :private_allow_list)

      assert scrubbed.private == %{phoenix_action: :show}
    end

    test "an empty allow_list drops all private keys", %{conn: conn} do
      :ok = Scrubber.put_conn_scrubber(private_allow_list: [])

      scrubbed = Scrubber.scrub(conn, private: :private_allow_list)

      assert scrubbed.private == %{}
    end
  end

  describe "default_private_allow_list/0" do
    test "returns Phoenix routing/render metadata keys" do
      allow_list = Scrubber.default_private_allow_list()

      assert :phoenix_controller in allow_list
      assert :phoenix_action in allow_list
      refute :plug_session in allow_list
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

    test "scrubs non-Plug.Conn structs by converting them to a map" do
      uri = URI.parse("http://example.com/path")

      scrubbed = Scrubber.scrub(uri)

      # The struct is converted to a plain map and scrubbed, never returned as-is.
      refute is_struct(scrubbed)
      assert is_map(scrubbed)
      assert scrubbed.host == "example.com"
    end

    test "redacts value-detectable secrets in a non-Plug.Conn struct" do
      scrubbed = Scrubber.scrub(%LeakyStruct{card_number: "4242424242424242", name: "Alice"})

      refute is_struct(scrubbed)
      # Once the struct is a map, value-based heuristics reach its fields: the
      # credit-card-shaped value is redacted, non-sensitive data is preserved.
      assert scrubbed.card_number == "*********"
      assert scrubbed.name == "Alice"
    end
  end
end
