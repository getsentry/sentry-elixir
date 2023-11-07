defmodule Sentry.EventTest do
  use ExUnit.Case, async: false

  alias Sentry.Event
  alias Sentry.Interfaces

  import Sentry.TestEnvironmentHelper

  doctest Event, import: true

  def event_generated_by_exception(extra \\ %{}) do
    try do
      apply(Event, :not_a_function, [1, 2, 3])
    rescue
      e -> Event.transform_exception(e, stacktrace: __STACKTRACE__, extra: extra)
    end
  end

  test "parses error exception" do
    event = event_generated_by_exception()

    assert event.platform == :elixir
    assert event.extra == %{}

    assert [
             %Interfaces.Exception{
               type: "UndefinedFunctionError",
               value: "function Sentry.Event.not_a_function/3 is undefined or private",
               module: nil,
               stacktrace: stacktrace
             }
           ] = event.exception

    assert event.level == :error
    assert event.message == nil

    assert is_binary(event.server_name)

    assert [
             %Interfaces.Stacktrace.Frame{
               context_line: nil,
               filename: "lib/ex_unit/runner.ex",
               function: _,
               in_app: false,
               lineno: _,
               module: ExUnit.Runner,
               post_context: [],
               pre_context: [],
               vars: %{}
             },
             %Interfaces.Stacktrace.Frame{
               context_line: nil,
               filename: "timer.erl",
               function: ":timer.tc" <> _arity,
               in_app: false,
               lineno: _,
               module: :timer,
               post_context: [],
               pre_context: [],
               vars: %{}
             },
             %Interfaces.Stacktrace.Frame{
               context_line: nil,
               filename: "lib/ex_unit/runner.ex",
               function: _,
               in_app: false,
               lineno: _,
               module: ExUnit.Runner,
               post_context: [],
               pre_context: [],
               vars: %{}
             },
             %Interfaces.Stacktrace.Frame{
               context_line: nil,
               filename: "test/event_test.exs",
               function: "Sentry.EventTest.\"test parses error exception\"/1",
               in_app: false,
               lineno: _,
               module: Sentry.EventTest,
               post_context: [],
               pre_context: [],
               vars: %{}
             },
             %Interfaces.Stacktrace.Frame{
               context_line: nil,
               filename: "test/event_test.exs",
               function: "Sentry.EventTest.event_generated_by_exception/1",
               in_app: false,
               lineno: _,
               module: Sentry.EventTest,
               post_context: [],
               pre_context: [],
               vars: %{}
             },
             %Interfaces.Stacktrace.Frame{
               context_line: nil,
               filename: nil,
               function: "Sentry.Event.not_a_function/3",
               in_app: false,
               lineno: nil,
               module: Sentry.Event,
               post_context: [],
               pre_context: [],
               vars: %{"arg0" => "1", "arg1" => "2", "arg2" => "3"}
             }
           ] = stacktrace.frames

    assert event.tags == %{}
    assert event.timestamp =~ ~r/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/
    assert is_binary(event.contexts.os.name)
    assert is_binary(event.contexts.os.version)
    assert is_binary(event.contexts.runtime.name)
    assert is_binary(event.contexts.runtime.version)
  end

  test "respects extra information passed in" do
    event = event_generated_by_exception(%{extra_data: "data"})
    assert event.extra == %{extra_data: "data"}
  end

  describe "create_event/1" do
    test "uses all the right defaults when called without options" do
      assert %Event{} = event = Event.create_event([])
      assert is_binary(event.event_id)
      assert is_binary(event.timestamp)
      assert is_binary(event.server_name)
      assert event.level == :error
      assert event.breadcrumbs == []
      assert %Interfaces.SDK{name: "sentry-elixir"} = event.sdk
      assert %{} = event.user
      assert %{} = event.request
      assert %{} = event.contexts
      assert event.release == nil
      assert event.exception == []
      assert event.message == nil
      assert map_size(event.modules) > 0
    end

    test "fills in passed-in options" do
      assert %Event{} = event = Event.create_event(level: :info)
      assert event.level == :info
    end

    test "fills in passed-in options and merges them with the context" do
      Sentry.Context.set_user_context(%{id: 1, username: "foo"})
      Sentry.Context.set_extra_context(%{weather: "sunny", temperature: 95})
      Sentry.Context.set_request_context(%{method: "GET", url: "https://a.com"})
      Sentry.Context.set_tags_context(%{scm: "svn", build: "123"})

      Sentry.Context.add_breadcrumb(level: :debug, message: "context1")
      Sentry.Context.add_breadcrumb(level: :info, message: "context2")

      assert %Event{} =
               event =
               Event.create_event(
                 user: %{id: 2, email: "foo@example.com"},
                 extra: %{weather: "rainy", humidity: 100},
                 request: %{method: "POST", data: "yes"},
                 tags: %{scm: "git", region: "eu"},
                 breadcrumbs: [
                   %{level: :info, message: "from create_event/1 1"},
                   %{level: :fatal, message: "from create_event/1 2"}
                 ]
               )

      assert event.user == %{id: 2, username: "foo", email: "foo@example.com"}

      assert event.request == %Interfaces.Request{
               method: "POST",
               url: "https://a.com",
               data: "yes"
             }

      assert event.extra == %{weather: "rainy", temperature: 95, humidity: 100}
      assert event.tags == %{scm: "git", build: "123", region: "eu"}

      assert [
               %Interfaces.Breadcrumb{level: :info, message: "from create_event/1 1"},
               %Interfaces.Breadcrumb{level: :fatal, message: "from create_event/1 2"},
               %Interfaces.Breadcrumb{level: :debug, message: "context1"},
               %Interfaces.Breadcrumb{level: :info, message: "context2"}
             ] = event.breadcrumbs

      for breadcrumb <- event.breadcrumbs, breadcrumb.message =~ "context" do
        assert is_integer(breadcrumb.timestamp)
      end
    end

    test "supports the :fingerprint option" do
      assert %Event{} = event = Event.create_event(fingerprint: ["foo", "bar"])
      assert event.fingerprint == ["foo", "bar"]
    end

    test "fills in the exception interface when passing :exception and :stacktrace" do
      {:current_stacktrace, stacktrace} = Process.info(self(), :current_stacktrace)

      assert %Event{} =
               event =
               Event.create_event(
                 exception: %RuntimeError{message: "foo"},
                 stacktrace: stacktrace
               )

      assert [
               %Interfaces.Exception{
                 type: "RuntimeError",
                 value: "foo",
                 stacktrace: %Interfaces.Stacktrace{frames: [stacktrace_frame | _rest]}
               }
             ] = event.exception

      assert %Interfaces.Stacktrace.Frame{} = stacktrace_frame
      assert is_binary(stacktrace_frame.filename)
      assert is_binary(stacktrace_frame.function)
      assert is_integer(stacktrace_frame.lineno)
    end

    test "fills in the exception interface when passing :exception without :stacktrace" do
      assert %Event{} =
               event = Event.create_event(exception: %RuntimeError{message: "foo"})

      assert event.exception == [
               %Interfaces.Exception{
                 type: "RuntimeError",
                 value: "foo"
               }
             ]
    end

    test "raises an error if passing :stacktrace without :exception" do
      assert_raise ArgumentError, ~r/cannot provide a :stacktrace/, fn ->
        Event.create_event(stacktrace: [])
      end
    end

    test "fills in the message interface when passing the :message option" do
      assert %Event{
               breadcrumbs: [],
               environment: "test",
               exception: [],
               extra: %{},
               level: :error,
               message: "Test message",
               platform: :elixir,
               release: nil,
               request: %{},
               tags: %{},
               user: %{},
               contexts: %{os: %{name: _, version: _}, runtime: %{name: _, version: _}}
             } = Event.create_event(message: "Test message")
    end

    test "fills in private (:__...__) fields" do
      exception = %RuntimeError{message: "foo"}

      assert %Event{} =
               event = Event.create_event(exception: exception, event_source: :plug)

      assert event.source == :plug
      assert event.original_exception == exception
    end

    test "raises if the :request option contains non-request fields" do
      assert_raise ArgumentError, ~r/unknown field for the request interface: :bad_key/, fn ->
        Event.create_event(request: %{method: "GET", bad_key: :indeed})
      end
    end
  end

  test "respects the max_breadcrumbs configuration" do
    breadcrumbs = for x <- 1..150, do: %{message: "breadcrumb-#{x}"}

    event = Event.create_event(message: "Test message", breadcrumbs: breadcrumbs)
    assert length(event.breadcrumbs) == 100

    assert event.breadcrumbs ==
             breadcrumbs |> Enum.take(-100) |> Enum.map(&struct(Interfaces.Breadcrumb, &1))
  end

  test "only sending fingerprint when set" do
    exception = RuntimeError.exception("error")
    event = Sentry.Event.transform_exception(exception, fingerprint: ["hello", "world"])
    assert event.fingerprint == ["hello", "world"]
  end

  test "not sending fingerprint when unset" do
    exception = RuntimeError.exception("error")
    event = Sentry.Event.transform_exception(exception, [])
    assert event.fingerprint == ["{{ default }}"]
  end

  test "sets :in_app to true when configured" do
    modify_env(:sentry, in_app_module_allow_list: [Sentry, :random, Sentry.Submodule])
    exception = RuntimeError.exception("error")

    event =
      Sentry.Event.transform_exception(
        exception,
        stacktrace: [
          {Elixir.Sentry.Fun, :method, 2, []},
          {Elixir.Sentry, :other_method, 4, []},
          {:other_module, :a_method, 8, []},
          {:random, :uniform, 0, []},
          {Sentry.Submodule.Fun, :this_method, 0, []}
        ]
      )

    assert [
             %Interfaces.Stacktrace.Frame{
               module: Sentry.Submodule.Fun,
               function: "Sentry.Submodule.Fun.this_method/0",
               in_app: true,
               filename: nil,
               lineno: nil,
               context_line: nil,
               post_context: [],
               pre_context: [],
               vars: %{}
             },
             %Interfaces.Stacktrace.Frame{
               module: :random,
               function: ":random.uniform/0",
               in_app: true,
               filename: nil,
               lineno: nil,
               context_line: nil,
               post_context: [],
               pre_context: [],
               vars: %{}
             },
             %Interfaces.Stacktrace.Frame{
               module: :other_module,
               function: ":other_module.a_method/8",
               in_app: false,
               filename: nil,
               lineno: nil,
               context_line: nil,
               post_context: [],
               pre_context: [],
               vars: %{}
             },
             %Interfaces.Stacktrace.Frame{
               module: Sentry,
               function: "Sentry.other_method/4",
               in_app: true,
               filename: nil,
               lineno: nil,
               context_line: nil,
               post_context: [],
               pre_context: [],
               vars: %{}
             },
             %Interfaces.Stacktrace.Frame{
               filename: nil,
               function: "Sentry.Fun.method/2",
               module: Sentry.Fun,
               lineno: nil,
               in_app: true,
               context_line: nil,
               post_context: [],
               pre_context: [],
               vars: %{}
             }
           ] == hd(event.exception).stacktrace.frames
  end

  test "transforms loaded applications to map of application -> version" do
    exception = RuntimeError.exception("error")
    event = Sentry.Event.transform_exception(exception, [])

    assert ["asn1", "bypass", "certifi", "compiler" | _rest] =
             event.modules
             |> Map.keys()
             |> Enum.sort()
  end
end
