defmodule Sentry.LogEventTest do
  use Sentry.Case, async: true

  alias Sentry.LogEvent

  import Sentry.TestHelpers

  setup do
    put_test_config(
      dsn: "http://public:secret@localhost/1",
      environment_name: "test"
    )

    :ok
  end

  describe "from_logger_event/3 with user-provided parameters" do
    test "interpolates %s placeholders with list parameters" do
      log_event = %{
        level: :info,
        msg: {:string, "Hello %s from %s"},
        meta: %{time: 1_000_000_000}
      }

      result = LogEvent.from_logger_event(log_event, %{}, ["Jane", "NYC"])

      assert result.body == "Hello Jane from NYC"
      assert result.template == "Hello %s from %s"
      assert result.parameters == ["Jane", "NYC"]
    end

    test "interpolates %{key} placeholders with map parameters" do
      log_event = %{
        level: :info,
        msg: {:string, "Hello %{name} from %{city}"},
        meta: %{time: 1_000_000_000}
      }

      result = LogEvent.from_logger_event(log_event, %{}, %{name: "Jane", city: "NYC"})

      assert result.body == "Hello Jane from NYC"
      assert result.template == "Hello %{name} from %{city}"
      assert result.parameters == ["Jane", "NYC"]
    end

    test "preserves parameter types with %s placeholders" do
      log_event = %{
        level: :info,
        msg: {:string, "Count: %s, Price: %s, Active: %s"},
        meta: %{time: 1_000_000_000}
      }

      result = LogEvent.from_logger_event(log_event, %{}, [42, 99.95, true])

      assert result.body == "Count: 42, Price: 99.95, Active: true"
      assert result.parameters == [42, 99.95, true]
    end

    test "preserves parameter types with %{key} placeholders" do
      log_event = %{
        level: :info,
        msg: {:string, "Count: %{count}, Price: %{price}"},
        meta: %{time: 1_000_000_000}
      }

      result = LogEvent.from_logger_event(log_event, %{}, %{count: 42, price: 99.95})

      assert result.body == "Count: 42, Price: 99.95"
      assert result.parameters == [42, 99.95]
    end
  end

  describe "from_logger_event/2" do
    test "extracts body from string message" do
      log_event = %{
        level: :info,
        msg: {:string, "Hello world"},
        meta: %{time: 1_000_000_000}
      }

      result = LogEvent.from_logger_event(log_event)

      assert result.body == "Hello world"
      assert result.level == :info
      assert result.template == nil
      assert result.parameters == nil
    end

    test "extracts template and parameters from format string" do
      log_event = %{
        level: :info,
        msg: {~c"User ~s logged in from ~s", ["jane_doe", "192.168.1.1"]},
        meta: %{time: 1_000_000_000}
      }

      result = LogEvent.from_logger_event(log_event)

      assert result.body == "User jane_doe logged in from 192.168.1.1"
      assert result.template == "User ~s logged in from ~s"
      assert result.parameters == ["jane_doe", "192.168.1.1"]
    end

    test "preserves numeric parameter types" do
      log_event = %{
        level: :info,
        msg: {~c"Count: ~p, Price: ~p", [42, 99.95]},
        meta: %{time: 1_000_000_000}
      }

      result = LogEvent.from_logger_event(log_event)

      assert result.body == "Count: 42, Price: 99.95"
      assert result.template == "Count: ~p, Price: ~p"
      assert result.parameters == [42, 99.95]
    end

    test "converts atom parameters to strings" do
      log_event = %{
        level: :info,
        msg: {~c"Status: ~p", [:ok]},
        meta: %{time: 1_000_000_000}
      }

      result = LogEvent.from_logger_event(log_event)

      assert result.body == "Status: ok"
      assert result.template == "Status: ~p"
      assert result.parameters == ["ok"]
    end

    test "inspects complex parameters" do
      log_event = %{
        level: :info,
        msg: {~c"Data: ~p", [%{key: "value"}]},
        meta: %{time: 1_000_000_000}
      }

      result = LogEvent.from_logger_event(log_event)

      assert result.template == "Data: ~p"
      assert result.parameters == [~s(%{key: "value"})]
    end

    test "handles report messages without template" do
      log_event = %{
        level: :info,
        msg: {:report, %{foo: "bar"}},
        meta: %{time: 1_000_000_000}
      }

      result = LogEvent.from_logger_event(log_event)

      assert result.body == ~s(%{foo: "bar"})
      assert result.template == nil
      assert result.parameters == nil
    end
  end

  describe "to_map/1" do
    test "includes template and parameters in attributes when present" do
      log_event = %LogEvent{
        level: :info,
        body: "User jane_doe logged in",
        timestamp: 1_000_000.5,
        template: "User ~s logged in",
        parameters: ["jane_doe"],
        attributes: %{}
      }

      result = LogEvent.to_map(log_event)

      assert result.attributes["sentry.message.template"] == %{
               value: "User ~s logged in",
               type: "string"
             }

      assert result.attributes["sentry.message.parameter.0"] == %{
               value: "jane_doe",
               type: "string"
             }
    end

    test "includes multiple parameters with correct indices" do
      log_event = %LogEvent{
        level: :info,
        body: "a=1, b=2, c=3",
        timestamp: 1_000_000.5,
        template: "a=~p, b=~p, c=~p",
        parameters: [1, 2, 3],
        attributes: %{}
      }

      result = LogEvent.to_map(log_event)

      assert result.attributes["sentry.message.parameter.0"] == %{value: 1, type: "integer"}
      assert result.attributes["sentry.message.parameter.1"] == %{value: 2, type: "integer"}
      assert result.attributes["sentry.message.parameter.2"] == %{value: 3, type: "integer"}
    end

    test "preserves parameter types in attributes" do
      log_event = %LogEvent{
        level: :info,
        body: "string, 42, 3.14, true",
        timestamp: 1_000_000.5,
        template: "~s, ~p, ~p, ~p",
        parameters: ["string", 42, 3.14, true],
        attributes: %{}
      }

      result = LogEvent.to_map(log_event)

      assert result.attributes["sentry.message.parameter.0"] == %{value: "string", type: "string"}
      assert result.attributes["sentry.message.parameter.1"] == %{value: 42, type: "integer"}
      assert result.attributes["sentry.message.parameter.2"] == %{value: 3.14, type: "double"}
      assert result.attributes["sentry.message.parameter.3"] == %{value: true, type: "boolean"}
    end

    test "does not include template attributes when template is nil" do
      log_event = %LogEvent{
        level: :info,
        body: "Plain message",
        timestamp: 1_000_000.5,
        template: nil,
        parameters: nil,
        attributes: %{}
      }

      result = LogEvent.to_map(log_event)

      refute Map.has_key?(result.attributes, "sentry.message.template")
      refute Map.has_key?(result.attributes, "sentry.message.parameter.0")
    end

    test "does not include template attributes when parameters is empty" do
      log_event = %LogEvent{
        level: :info,
        body: "Message",
        timestamp: 1_000_000.5,
        template: "Message",
        parameters: [],
        attributes: %{}
      }

      result = LogEvent.to_map(log_event)

      refute Map.has_key?(result.attributes, "sentry.message.template")
      refute Map.has_key?(result.attributes, "sentry.message.parameter.0")
    end
  end
end
