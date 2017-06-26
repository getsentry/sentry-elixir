defmodule Sentry.EventTest do
  use ExUnit.Case, async: true
  alias Sentry.Event
  import Sentry.TestEnvironmentHelper

  def event_generated_by_exception(extra \\ %{}) do
    try do
      Event.not_a_function
    rescue
      e -> Event.transform_exception(e, [stacktrace: System.stacktrace, extra: extra])
    end
  end

  test "parses error exception" do
    event = event_generated_by_exception()

    assert event.platform == "elixir"
    assert event.culprit == "Sentry.Event.not_a_function()"
    assert event.extra == %{}
    assert event.exception == [
      %{type: UndefinedFunctionError,
       value: "function Sentry.Event.not_a_function/0 is undefined or private",
       module: nil}
    ]
    assert event.level == "error"
    assert event.message == "(UndefinedFunctionError) function Sentry.Event.not_a_function/0 is undefined or private"
    assert is_binary(event.server_name)
    assert event.stacktrace == %{frames: Enum.reverse([
      %{filename: nil, function: "Sentry.Event.not_a_function/0", lineno: nil, module: Sentry.Event, context_line: nil, post_context: [], pre_context: []},
      %{filename: "test/event_test.exs", function: "Sentry.EventTest.event_generated_by_exception/1", lineno: 8, module: Sentry.EventTest, context_line: nil, post_context: [], pre_context: []},
      %{filename: "test/event_test.exs", function: "Sentry.EventTest.\"test parses error exception\"/1", lineno: 15, module: Sentry.EventTest, context_line: nil, post_context: [], pre_context: []},
      %{filename: "lib/ex_unit/runner.ex", function: "ExUnit.Runner.exec_test/1", lineno: 302, module: ExUnit.Runner, context_line: nil, post_context: [], pre_context: []},
      %{filename: "timer.erl", function: ":timer.tc/1", lineno: 166, module: :timer, context_line: nil, post_context: [], pre_context: []},
      %{filename: "lib/ex_unit/runner.ex", function: "anonymous fn/3 in ExUnit.Runner.spawn_test/3", lineno: 250, module: ExUnit.Runner, context_line: nil, post_context: [], pre_context: []}])
    }
    assert event.tags == %{}
    assert event.timestamp =~ ~r/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/
  end

  test "respects tags in config" do
    modify_env(:sentry, tags: %{testing: "tags"})
    event = event_generated_by_exception()
    assert event.tags == %{testing: "tags"}
  end

  test "respects extra information passed in" do
    event = event_generated_by_exception(%{extra_data: "data"})
    assert event.extra == %{extra_data: "data"}
  end

  test "create_event works for message" do
    %Sentry.Event{
      breadcrumbs: [],
      culprit: nil,
      environment: :test,
      exception: nil,
      extra: %{},
      level: "error",
      message: "Test message",
      platform: "elixir",
      release: nil,
      request: %{},
      stacktrace: %{frames: []},
      tags: %{},
      user: %{}} = Event.create_event(message: "Test message")
  end
end
