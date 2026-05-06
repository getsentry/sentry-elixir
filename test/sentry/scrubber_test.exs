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
end
