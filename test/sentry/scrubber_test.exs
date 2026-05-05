defmodule Sentry.ScrubberTest do
  use ExUnit.Case, async: true

  alias Sentry.Scrubber

  describe "scrub_map/1" do
    test "redacts default sensitive keys" do
      assert Scrubber.scrub_map(%{"password" => "hunter2", "username" => "alice"}) ==
               %{"password" => "[Filtered]", "username" => "alice"}

      assert Scrubber.scrub_map(%{"passwd" => "x", "secret" => "y", "ok" => "z"}) ==
               %{"passwd" => "[Filtered]", "secret" => "[Filtered]", "ok" => "z"}
    end

    test "matches keys case-insensitively" do
      assert Scrubber.scrub_map(%{"Password" => "x", "PASSWORD" => "y"}) ==
               %{"Password" => "[Filtered]", "PASSWORD" => "[Filtered]"}
    end

    test "matches keys as substrings (e.g. auth matches Authorization)" do
      assert Scrubber.scrub_map(%{"Authorization" => "Bearer xyz"}) ==
               %{"Authorization" => "[Filtered]"}

      assert Scrubber.scrub_map(%{"X-Auth-Token" => "abc"}) ==
               %{"X-Auth-Token" => "[Filtered]"}

      assert Scrubber.scrub_map(%{"api_key" => "k", "session_id" => "s"}) ==
               %{"api_key" => "[Filtered]", "session_id" => "[Filtered]"}
    end

    test "matches every term in the spec denylist" do
      for term <- [
            "auth",
            "token",
            "secret",
            "password",
            "passwd",
            "pwd",
            "key",
            "jwt",
            "bearer",
            "sso",
            "saml",
            "csrf",
            "xsrf",
            "credentials",
            "session",
            "sid",
            "identity"
          ] do
        assert Scrubber.scrub_map(%{term => "v"}) == %{term => "[Filtered]"}
      end
    end

    test "redacts credit card-like values" do
      assert Scrubber.scrub_map(%{"card" => "4111111111111111"}) ==
               %{"card" => "[Filtered]"}
    end

    test "leaves non-sensitive data untouched" do
      data = %{"username" => "alice", "age" => 30, "active" => true}
      assert Scrubber.scrub_map(data) == data
    end

    test "scrubs atom keys" do
      assert Scrubber.scrub_map(%{password: "x", name: "alice"}) ==
               %{password: "[Filtered]", name: "alice"}
    end

    test "recurses into nested maps" do
      assert Scrubber.scrub_map(%{"user" => %{"password" => "x", "name" => "alice"}}) ==
               %{"user" => %{"password" => "[Filtered]", "name" => "alice"}}
    end

    test "recurses into lists of maps" do
      assert Scrubber.scrub_map(%{"users" => [%{"password" => "x"}, %{"password" => "y"}]}) ==
               %{"users" => [%{"password" => "[Filtered]"}, %{"password" => "[Filtered]"}]}
    end

    test "recurses into structs by converting them to maps" do
      struct = %URI{scheme: "https", host: "example.com"}
      result = Scrubber.scrub_map(%{"uri" => struct})
      assert result["uri"].host == "example.com"
    end
  end

  describe "scrub_map/2" do
    test "extends the denylist with extra terms" do
      assert Scrubber.scrub_map(%{"my_custom" => "v", "ok" => "x"}, ["custom"]) ==
               %{"my_custom" => "[Filtered]", "ok" => "x"}
    end
  end

  describe "scrub_string/1" do
    test "always returns the placeholder" do
      assert Scrubber.scrub_string("anything at all") == "[Filtered]"
    end
  end

  describe "default_scrubbed_param_keys/0" do
    test "returns the spec-conformant default sensitive keys" do
      keys = Scrubber.default_scrubbed_param_keys()
      assert "auth" in keys
      assert "token" in keys
      assert "jwt" in keys
      assert "session" in keys
      assert length(keys) == 17
    end
  end

  describe "scrubbed_value/0" do
    test "returns the spec-conformant placeholder" do
      assert Scrubber.scrubbed_value() == "[Filtered]"
    end
  end
end
