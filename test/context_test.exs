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

  test "passing in extra context as option overrides Sentry.Context" do
    Sentry.Context.set_extra_context(%{"key" => "345", "key1" => "123"})

    exception = RuntimeError.exception("error")
    event = Sentry.Event.transform_exception(exception, [extra: %{"key" => "123"}])

    assert event.extra == %{"key" => "123", "key1" => "123"}
    assert event.tags == %{}
    assert event.user == %{}
  end

  test "passing in tags context as option overrides Sentry.Context and Application config" do
    Sentry.Context.set_tags_context(%{"key" => "345", "key1" => "123"})
    Application.put_env(:sentry, :tags, %{"key" => "overridden", "key2" => "1234", "key3" => "12345"})

    exception = RuntimeError.exception("error")
    event = Sentry.Event.transform_exception(exception, [tags: %{"key" => "123"}])

    assert event.tags == %{"key" => "123", "key1" => "123", "key2" => "1234", "key3" => "12345"}
    assert event.extra == %{}
    assert event.user == %{}
    Application.put_env(:sentry, :tags, %{})
  end

  test "passing in user context as option overrides Sentry.Context" do
    Sentry.Context.set_user_context(%{"key" => "345", "key1" => "123"})

    exception = RuntimeError.exception("error")
    event = Sentry.Event.transform_exception(exception, [user: %{"key" => "123"}])

    assert event.user == %{"key" => "123", "key1" => "123"}
    assert event.extra == %{}
    assert event.tags == %{}
  end
end
