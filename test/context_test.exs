defmodule Sentry.ContextTest do
  use Sentry.Case, async: false

  import Sentry.TestHelpers

  alias Sentry.{Context, Event, Interfaces}

  doctest Context, except: [add_breadcrumb: 1]

  setup do
    %{exception: RuntimeError.exception("error")}
  end

  test "storing extra context appears when generating event" do
    Context.set_extra_context(%{"key" => "345"})

    event = Event.create_event([])

    assert event.extra == %{"key" => "345"}
    assert event.tags == %{}
    assert event.user == %{}
  end

  test "storing breadcrumbs appears when generating event" do
    Context.add_breadcrumb(category: "a category", message: "a message")
    Context.add_breadcrumb(%{category: "a category", message: "second message"})

    event = Event.create_event([])

    [first_breadcrumb, second_breadcrumb] = event.breadcrumbs

    assert event.user == %{}
    assert event.extra == %{}
    assert event.tags == %{}
    assert first_breadcrumb.category == "a category"
    assert second_breadcrumb.category == "a category"
    assert first_breadcrumb.message == "a message"
    assert second_breadcrumb.message == "second message"
    assert first_breadcrumb.timestamp <= second_breadcrumb.timestamp
  end

  test "storing user context appears when generating event" do
    Context.set_user_context(%{id: "345"})

    event = Event.create_event([])

    assert event.user == %{id: "345"}
    assert event.extra == %{}
    assert event.tags == %{}
  end

  test "storing tags context appears when generating event" do
    Context.set_tags_context(%{"key" => "345"})

    event = Event.create_event([])

    assert event.tags == %{"key" => "345"}
    assert event.extra == %{}
    assert event.user == %{}
  end

  test "storing request context appears when generating event" do
    Context.set_request_context(%{url: "https://wow"})

    event = Event.create_event(request: %{method: "GET"})

    assert event.request == %Interfaces.Request{url: "https://wow", method: "GET"}
  end

  test "passing in extra context as option overrides Context" do
    Context.set_extra_context(%{"key" => "345", "key1" => "123"})

    event = Event.create_event(extra: %{"key" => "123"})

    assert event.extra == %{"key" => "123", "key1" => "123"}
    assert event.tags == %{}
    assert event.user == %{}
  end

  test "passing in tags context as option overrides Context and Application config" do
    Context.set_tags_context(%{"key" => "345", "key1" => "123"})
    put_test_config(tags: %{"key" => "overridden", "key2" => "1234", "key3" => "12345"})
    event = Event.create_event(tags: %{"key" => "123"})

    assert event.tags == %{"key" => "123", "key1" => "123", "key2" => "1234", "key3" => "12345"}
    assert event.extra == %{}
    assert event.user == %{}
  end

  test "passing in user context as option overrides Context" do
    Context.set_user_context(%{id: "123"})

    event = Event.create_event(user: %{id: "456"})

    assert event.user == %{id: "456"}
    assert event.extra == %{}
    assert event.tags == %{}
  end
end
