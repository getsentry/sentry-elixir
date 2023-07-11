defmodule Sentry.EventTest do
  use ExUnit.Case
  alias Sentry.Event
  import Sentry.TestEnvironmentHelper

  def event_generated_by_exception(extra \\ %{}) do
    try do
      apply(Event, :not_a_function, [1, 2, 3])
    rescue
      e -> Event.transform_exception(e, stacktrace: __STACKTRACE__, extra: extra)
    end
  end

  def get_stacktrace_frames_for_elixir() do
  end

  test "parses error exception" do
    event = event_generated_by_exception()

    assert event.platform == "elixir"
    assert event.culprit == "Sentry.Event.not_a_function/3"
    assert event.extra == %{}

    assert event.exception == [
             %{
               type: "UndefinedFunctionError",
               value: "function Sentry.Event.not_a_function/3 is undefined or private",
               module: nil
             }
           ]

    assert event.level == "error"

    assert event.message ==
             "(UndefinedFunctionError function Sentry.Event.not_a_function/3 is undefined or private)"

    assert is_binary(event.server_name)

    assert %{
             frames: [
               %{
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
               %{
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
               %{
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
               %{
                 context_line: nil,
                 filename: "test/event_test.exs",
                 function: "Sentry.EventTest.\"test parses error exception\"/1",
                 in_app: false,
                 lineno: 18,
                 module: Sentry.EventTest,
                 post_context: [],
                 pre_context: [],
                 vars: %{}
               },
               %{
                 context_line: nil,
                 filename: "test/event_test.exs",
                 function: "Sentry.EventTest.event_generated_by_exception/1",
                 in_app: false,
                 lineno: 8,
                 module: Sentry.EventTest,
                 post_context: [],
                 pre_context: [],
                 vars: %{}
               },
               %{
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
             ]
           } = event.stacktrace

    assert event.tags == %{}
    assert event.timestamp =~ ~r/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/
    assert is_binary(event.contexts.os.name)
    assert is_binary(event.contexts.os.version)
    assert is_binary(event.contexts.runtime.name)
    assert is_binary(event.contexts.runtime.version)
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
      user: %{},
      contexts: %{os: %{name: _, version: _}, runtime: %{name: _, version: _}}
    } = Event.create_event(message: "Test message")
  end

  test "respects the max_breadcrumbs configuration" do
    breadcrumbs =
      1..150
      |> Enum.map(fn x -> %{message: "breadcrumb-#{x}"} end)

    event = Event.create_event(message: "Test message", breadcrumbs: breadcrumbs)
    assert length(event.breadcrumbs) == 100
    assert event.breadcrumbs == Enum.take(breadcrumbs, -100)
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

  test "sets app_frame to true when configured" do
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

    assert %{
             frames: [
               %{
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
               %{
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
               %{
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
               %{
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
               %{
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
             ]
           } == event.stacktrace
  end

  test "transforms mix deps to map of modules" do
    exception = RuntimeError.exception("error")
    event = Sentry.Event.transform_exception(exception, [])

    modules =
      event.modules
      |> Map.keys()
      |> Enum.sort()

    assert modules == [
             :bypass,
             :certifi,
             :cowboy,
             :cowboy_telemetry,
             :cowlib,
             :dialyxir,
             :erlex,
             :hackney,
             :idna,
             :jason,
             :metrics,
             :mime,
             :mimerl,
             :parse_trans,
             :phoenix,
             :phoenix_html,
             :phoenix_pubsub,
             :plug,
             :plug_cowboy,
             :plug_crypto,
             :ranch,
             :ssl_verify_fun,
             :telemetry,
             :unicode_util_compat
           ]
  end
end
