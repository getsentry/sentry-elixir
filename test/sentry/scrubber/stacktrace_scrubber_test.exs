defmodule Sentry.Scrubber.StacktraceScrubberTest.Card do
  @moduledoc false
  defstruct [:card_number, :name, :secret]
end

defmodule Sentry.Scrubber.StacktraceScrubberTest do
  use ExUnit.Case, async: true

  alias Sentry.Scrubber.StacktraceScrubber
  alias Sentry.Scrubber.StacktraceScrubberTest.Card

  describe "scrub_args/1" do
    test "scrubs each arg with Sentry.Scrubber.scrub/1" do
      conn = %Plug.Conn{
        req_headers: [{"authorization", "Bearer secret"}, {"x-keep", "yes"}],
        params: %{"password" => "secret", "name" => "Alice"}
      }

      args = [conn, %{"password" => "another", "ok" => "fine"}, "plain", 42]

      assert [scrubbed_conn, scrubbed_map, "plain", 42] = StacktraceScrubber.scrub_args(args)

      # the conn is scrubbed as a conn
      assert scrubbed_conn.params == %{"password" => "*********", "name" => "Alice"}
      assert scrubbed_conn.req_headers == [{"x-keep", "yes"}]

      # a plain map is key-scrubbed
      assert scrubbed_map == %{"password" => "*********", "ok" => "fine"}
    end

    test "scrubs a non-Plug.Conn struct's fields but keeps its type" do
      args = [%Card{card_number: "4242424242424242", name: "Alice", secret: "top-secret"}]

      assert [scrubbed] = StacktraceScrubber.scrub_args(args)

      # The struct keeps its type (so it inspects as %Card{...} in the frame var,
      # not a bare map)...
      assert is_struct(scrubbed, Card)
      # ...while its fields are scrubbed by value (credit-card heuristic) and by
      # name (the atom key :secret matches the sensitive-key list).
      assert scrubbed.card_number == "*********"
      assert scrubbed.secret == "*********"
      assert scrubbed.name == "Alice"
    end

    test "scrubs each arg independently, with no conn/params mirroring" do
      # A registered body_scrubber only governs the conn's params field; the standalone
      # params arg is scrubbed independently with the default keys (no mirror).
      Sentry.Scrubber.put_conn_scrubber(body_scrubber: fn _conn -> %{"marker" => "scrubbed"} end)

      conn = %Plug.Conn{params: %{"password" => "secret", "ssn" => "123-45-6789"}}
      args = [conn, conn.params]

      assert [scrubbed_conn, scrubbed_params] = StacktraceScrubber.scrub_args(args)

      # conn's params field goes through the registered body_scrubber
      assert scrubbed_conn.params == %{"marker" => "scrubbed"}

      # the standalone params arg is scrubbed independently (default keys only): the
      # "password" value is redacted, but "ssn" (not a default key) is left intact —
      # proving the conn's scrubbed params are NOT mirrored onto it.
      assert scrubbed_params == %{"password" => "*********", "ssn" => "123-45-6789"}
    end
  end

  describe "scrub/2" do
    test "scrubs an exception's :args with the default per-arg scrubber" do
      conn = %Plug.Conn{params: %{"password" => "secret", "name" => "Alice"}}
      exception = %FunctionClauseError{module: Foo, function: :bar, arity: 2, args: [conn, "x"]}

      assert %FunctionClauseError{args: [scrubbed_conn, "x"]} =
               StacktraceScrubber.scrub(exception)

      assert scrubbed_conn.params == %{"password" => "*********", "name" => "Alice"}
    end

    test "applies a custom args_scrubber callback to the exception's args" do
      exception = %FunctionClauseError{module: Foo, function: :bar, arity: 2, args: [1, 2, 3]}

      assert %FunctionClauseError{args: [2, 4, 6]} =
               StacktraceScrubber.scrub(exception, fn args -> Enum.map(args, &(&1 * 2)) end)
    end

    test "leaves an exception without a list :args field unchanged" do
      exception = %RuntimeError{message: "boom"}

      assert StacktraceScrubber.scrub(exception) == exception
    end
  end
end
