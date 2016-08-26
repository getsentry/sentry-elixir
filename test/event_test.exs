defmodule Sentry.EventTest do
  use ExUnit.Case, async: true
  alias Sentry.Event

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
       value: "function Sentry.Event.not_a_function/0 is undefined or private"}
    ]
    assert event.level == "error"
    assert event.message()== "(UndefinedFunctionError) function Sentry.Event.not_a_function/0 is undefined or private"
    assert is_binary(event.server_name)
    assert event.stacktrace == %{frames: Enum.reverse([
      %{filename: nil, function: "Sentry.Event.not_a_function()", lineno: nil, module: Sentry.Event},
      %{filename: "test/event_test.exs", function: "Sentry.EventTest.event_generated_by_exception/1", lineno: 7, module: Sentry.EventTest},
      %{filename: "test/event_test.exs", function: "Sentry.EventTest.\"test parses error exception\"/1", lineno: 14, module: Sentry.EventTest},
      %{filename: "lib/ex_unit/runner.ex", function: "ExUnit.Runner.exec_test/1", lineno: 296, module: ExUnit.Runner},
      %{filename: "timer.erl", function: ":timer.tc/1", lineno: 166, module: :timer},
      %{filename: "lib/ex_unit/runner.ex", function: "anonymous fn/3 in ExUnit.Runner.spawn_test/3", lineno: 246, module: ExUnit.Runner}])
    }
    assert event.tags == %{}
    assert event.timestamp =~ ~r/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}Z/
  end

  test "respects tags in config" do
    Application.put_env(:sentry, :tags, %{testing: "tags"})
    event = event_generated_by_exception()
    assert event.tags == %{testing: "tags"}
    Application.put_env(:sentry, :tags, %{})
  end

  test "respects extra information passed in" do
    event = event_generated_by_exception(%{extra_data: "data"})
    assert event.extra == %{extra_data: "data"}
  end
end
