defmodule Sentry.ContextTest do
  use ExUnit.Case

  test "storing extra context appears when generating event" do
    Sentry.Context.set_extra_context(%{"key" => "345"})

    exception = RuntimeError.exception("error")
    event = Sentry.Event.transform_exception(exception, [])

    assert event.extra == %{"key" => "345"}
    assert event.tags == %{}
    assert event.user == %{}
  end

  test "storing user context appears when generating event" do
    Sentry.Context.set_user_context(%{"key" => "345"})

    exception = RuntimeError.exception("error")
    event = Sentry.Event.transform_exception(exception, [])

    assert event.user == %{"key" => "345"}
    assert event.extra == %{}
    assert event.tags == %{}
  end

  test "storing tags context appears when generating event" do
    Sentry.Context.set_tags_context(%{"key" => "345"})

    exception = RuntimeError.exception("error")
    event = Sentry.Event.transform_exception(exception, [])

    assert event.tags == %{"key" => "345"}
    assert event.extra == %{}
    assert event.user == %{}
  end
end
