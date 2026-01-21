defmodule Sentry.Opentelemetry.SpanProcessorTest do
  use Sentry.Case, async: false

  require OpenTelemetry.Tracer, as: Tracer
  require OpenTelemetry.SemConv.Incubating.HTTPAttributes, as: HTTPAttributes
  require OpenTelemetry.SemConv.Incubating.URLAttributes, as: URLAttributes
  require OpenTelemetry.SemConv.Incubating.DBAttributes, as: DBAttributes
  require OpenTelemetry.SemConv.ClientAttributes, as: ClientAttributes
  require OpenTelemetry.SemConv.Incubating.MessagingAttributes, as: MessagingAttributes

  import Sentry.TestHelpers

  alias Sentry.OpenTelemetry.SpanStorage

  defmodule TestEndpoint do
    require OpenTelemetry.Tracer, as: Tracer

    def instrumented_function do
      Tracer.with_span "instrumented_function" do
        Process.sleep(100)

        child_instrumented_function("one")
        child_instrumented_function("two")
      end
    end

    def child_instrumented_function(name) do
      Tracer.with_span "child_instrumented_function_#{name}" do
        Process.sleep(140)
      end
    end
  end

  @tag span_storage: true
  test "sends captured root spans as transactions" do
    put_test_config(environment_name: "test", traces_sample_rate: 1.0)

    Sentry.Test.start_collecting_sentry_reports()

    TestEndpoint.child_instrumented_function("one")

    assert [%Sentry.Transaction{} = transaction] = Sentry.Test.pop_sentry_transactions()

    assert transaction.event_id
    assert transaction.environment == "test"
    assert transaction.transaction_info == %{source: :custom}
    assert_valid_iso8601(transaction.timestamp)
    assert_valid_iso8601(transaction.start_timestamp)
    assert transaction.timestamp > transaction.start_timestamp
    assert_valid_trace_id(transaction.contexts.trace.trace_id)
    assert length(transaction.spans) == 0
  end

  @tag span_storage: true
  test "sends captured spans as transactions with child spans" do
    put_test_config(environment_name: "test", traces_sample_rate: 1.0)

    Sentry.Test.start_collecting_sentry_reports()

    TestEndpoint.instrumented_function()

    assert [%Sentry.Transaction{} = transaction] = Sentry.Test.pop_sentry_transactions()

    assert_valid_iso8601(transaction.timestamp)
    assert_valid_iso8601(transaction.start_timestamp)
    assert transaction.timestamp > transaction.start_timestamp
    assert length(transaction.spans) == 2

    [child_span_one, child_span_two] = transaction.spans
    assert child_span_one.op == "child_instrumented_function_one"
    assert child_span_two.op == "child_instrumented_function_two"
    assert child_span_one.parent_span_id == transaction.contexts.trace.span_id
    assert child_span_two.parent_span_id == transaction.contexts.trace.span_id

    assert_valid_iso8601(child_span_one.timestamp)
    assert_valid_iso8601(child_span_one.start_timestamp)
    assert_valid_iso8601(child_span_two.timestamp)
    assert_valid_iso8601(child_span_two.start_timestamp)

    assert child_span_one.timestamp > child_span_one.start_timestamp
    assert child_span_two.timestamp > child_span_two.start_timestamp
    assert transaction.timestamp >= child_span_one.timestamp
    assert transaction.timestamp >= child_span_two.timestamp
    assert transaction.start_timestamp <= child_span_one.start_timestamp
    assert transaction.start_timestamp <= child_span_two.start_timestamp

    assert_valid_trace_id(transaction.contexts.trace.trace_id)
    assert_valid_trace_id(child_span_one.trace_id)
    assert_valid_trace_id(child_span_two.trace_id)
  end

  @tag span_storage: true
  test "removes span records from storage after sending a transaction", %{table_name: table_name} do
    put_test_config(environment_name: "test", traces_sample_rate: 1.0)

    Sentry.Test.start_collecting_sentry_reports()

    TestEndpoint.instrumented_function()

    assert [%Sentry.Transaction{} = transaction] = Sentry.Test.pop_sentry_transactions()

    assert SpanStorage.get_root_span(transaction.contexts.trace.span_id, table_name: table_name) ==
             nil

    assert [] ==
             SpanStorage.get_child_spans(transaction.contexts.trace.span_id,
               table_name: table_name
             )
  end

  defp assert_valid_iso8601(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, datetime, _offset} ->
        assert datetime.year >= 2023, "Expected year to be 2023 or later, got: #{datetime.year}"
        assert is_binary(timestamp), "Expected timestamp to be a string"
        assert String.ends_with?(timestamp, "Z"), "Expected timestamp to end with 'Z'"

      {:error, reason} ->
        flunk("Invalid ISO8601 timestamp: #{timestamp}, reason: #{inspect(reason)}")
    end
  end

  defp assert_valid_trace_id(trace_id) do
    assert is_binary(trace_id), "Expected trace_id to be a string"
    assert byte_size(trace_id) == 32, "Expected trace_id to be 32 characters long #{trace_id}"

    assert String.match?(trace_id, ~r/^[a-f0-9]{32}$/),
           "Expected trace_id to be a lowercase hex string"
  end

  describe "sampling behavior with root and child spans" do
    @tag span_storage: true
    test "drops entire trace when root span is not sampled" do
      put_test_config(environment_name: "test", traces_sample_rate: 0.0)

      original_sampler = Application.get_env(:opentelemetry, :sampler)
      Application.put_env(:opentelemetry, :sampler, {Sentry.OpenTelemetry.Sampler, [drop: []]})

      Sentry.Test.start_collecting_sentry_reports()

      Enum.each(1..5, fn _ ->
        TestEndpoint.instrumented_function()
      end)

      assert [] = Sentry.Test.pop_sentry_transactions()

      Application.put_env(:opentelemetry, :sampler, original_sampler)
    end

    @tag span_storage: true
    test "samples entire trace when root span is sampled" do
      put_test_config(environment_name: "test", traces_sample_rate: 1.0)

      Sentry.Test.start_collecting_sentry_reports()

      TestEndpoint.instrumented_function()

      assert [%Sentry.Transaction{} = transaction] = Sentry.Test.pop_sentry_transactions()
      assert length(transaction.spans) == 2

      [child_span_one, child_span_two] = transaction.spans
      assert transaction.contexts.trace.trace_id == child_span_one.trace_id
      assert transaction.contexts.trace.trace_id == child_span_two.trace_id
    end

    @tag span_storage: true
    test "child spans inherit parent sampling decision" do
      put_test_config(environment_name: "test", traces_sample_rate: 0.5)

      original_sampler = Application.get_env(:opentelemetry, :sampler)
      Application.put_env(:opentelemetry, :sampler, {Sentry.OpenTelemetry.Sampler, [drop: []]})

      Sentry.Test.start_collecting_sentry_reports()

      Enum.each(1..10, fn _ ->
        TestEndpoint.instrumented_function()
      end)

      transactions = Sentry.Test.pop_sentry_transactions()

      Enum.each(transactions, fn transaction ->
        assert length(transaction.spans) == 2

        [child_span_one, child_span_two] = transaction.spans
        assert transaction.contexts.trace.trace_id == child_span_one.trace_id
        assert transaction.contexts.trace.trace_id == child_span_two.trace_id
      end)

      Application.put_env(:opentelemetry, :sampler, original_sampler)
    end

    @tag span_storage: true
    test "nested child spans maintain hierarchy" do
      put_test_config(environment_name: "test", traces_sample_rate: 1.0)

      Sentry.Test.start_collecting_sentry_reports()

      Tracer.with_span "root_span" do
        Tracer.with_span "level_1_child" do
          Tracer.with_span "level_2_child" do
            Process.sleep(1)
          end

          Tracer.with_span "level_2_sibling" do
            Process.sleep(1)
          end
        end

        Tracer.with_span "level_1_sibling" do
          Process.sleep(1)
        end
      end

      assert [%Sentry.Transaction{} = transaction] = Sentry.Test.pop_sentry_transactions()

      assert length(transaction.spans) == 4

      trace_id = transaction.contexts.trace.trace_id

      Enum.each(transaction.spans, fn span ->
        assert span.trace_id == trace_id
      end)

      span_names = Enum.map(transaction.spans, & &1.op) |> Enum.sort()
      expected_names = ["level_1_child", "level_1_sibling", "level_2_child", "level_2_sibling"]
      assert span_names == expected_names
    end

    @tag span_storage: true
    test "child-only spans without root are handled correctly" do
      put_test_config(environment_name: "test", traces_sample_rate: 1.0)

      Sentry.Test.start_collecting_sentry_reports()

      TestEndpoint.child_instrumented_function("standalone")

      assert [%Sentry.Transaction{} = transaction] = Sentry.Test.pop_sentry_transactions()

      assert length(transaction.spans) == 0
      assert transaction.transaction == "child_instrumented_function_standalone"
    end

    @tag span_storage: true
    test "concurrent traces maintain independent sampling decisions" do
      put_test_config(environment_name: "test", traces_sample_rate: 0.5)

      original_sampler = Application.get_env(:opentelemetry, :sampler)
      Application.put_env(:opentelemetry, :sampler, {Sentry.OpenTelemetry.Sampler, [drop: []]})

      Sentry.Test.start_collecting_sentry_reports()

      tasks =
        Enum.map(1..20, fn i ->
          Task.async(fn ->
            Tracer.with_span "concurrent_root_#{i}" do
              Tracer.with_span "concurrent_child_#{i}" do
                Process.sleep(10)
              end
            end
          end)
        end)

      Enum.each(tasks, &Task.await/1)

      transactions = Sentry.Test.pop_sentry_transactions()

      Enum.each(transactions, fn transaction ->
        assert length(transaction.spans) == 1
        [child_span] = transaction.spans
        assert child_span.trace_id == transaction.contexts.trace.trace_id
      end)

      assert length(transactions) < 20

      Application.put_env(:opentelemetry, :sampler, original_sampler)
    end

    @tag span_storage: true
    test "span processor respects sampler drop configuration" do
      put_test_config(environment_name: "test", traces_sample_rate: 1.0)

      original_sampler = Application.get_env(:opentelemetry, :sampler)

      Application.put_env(
        :opentelemetry,
        :sampler,
        {Sentry.OpenTelemetry.Sampler, [drop: ["child_instrumented_function_one"]]}
      )

      Sentry.Test.start_collecting_sentry_reports()

      Tracer.with_span "root_span" do
        Tracer.with_span "child_instrumented_function_one" do
          Process.sleep(10)
        end

        Tracer.with_span "allowed_child" do
          Process.sleep(10)
        end
      end

      transactions = Sentry.Test.pop_sentry_transactions()

      Enum.each(transactions, fn transaction ->
        trace_id = transaction.contexts.trace.trace_id

        Enum.each(transaction.spans, fn span ->
          assert span.trace_id == trace_id
        end)
      end)

      Application.put_env(:opentelemetry, :sampler, original_sampler)
    end

    @tag span_storage: true
    test "treats HTTP server request spans as transaction roots for distributed tracing" do
      put_test_config(environment_name: "test", traces_sample_rate: 1.0)

      Sentry.Test.start_collecting_sentry_reports()

      # Simulate an incoming HTTP request with an external parent span ID (from browser/client)
      # This represents a distributed trace where the client started the trace
      external_trace_id = 0x1234567890ABCDEF1234567890ABCDEF
      external_parent_span_id = 0xABCDEF1234567890

      # Create a remote parent span context using :otel_tracer.from_remote_span
      remote_parent = :otel_tracer.from_remote_span(external_trace_id, external_parent_span_id, 1)

      ctx = Tracer.set_current_span(:otel_ctx.new(), remote_parent)

      # Start an HTTP server span with the remote parent context
      Tracer.with_span ctx, "POST /api/users", %{
        kind: :server,
        attributes: %{
          HTTPAttributes.http_request_method() => :POST,
          URLAttributes.url_path() => "/api/users",
          "http.route" => "/api/users",
          "server.address" => "localhost",
          "server.port" => 4000
        }
      } do
        # Simulate child spans (database queries, etc.)
        Tracer.with_span "db.query:users", %{
          kind: :client,
          attributes: %{
            "db.system" => :postgresql,
            "db.statement" => "INSERT INTO users (name) VALUES ($1)"
          }
        } do
          Process.sleep(10)
        end

        Tracer.with_span "db.query:notifications", %{
          kind: :client,
          attributes: %{
            "db.system" => :postgresql,
            "db.statement" => "INSERT INTO notifications (user_id) VALUES ($1)"
          }
        } do
          Process.sleep(10)
        end
      end

      # Should capture the HTTP request span as a transaction root despite having an external parent
      assert [%Sentry.Transaction{} = transaction] = Sentry.Test.pop_sentry_transactions()

      # Verify transaction properties
      assert transaction.transaction == "POST /api/users"
      assert transaction.transaction_info == %{source: :custom}
      assert length(transaction.spans) == 2

      # Verify child spans are properly included
      span_ops = Enum.map(transaction.spans, & &1.op) |> Enum.sort()
      assert span_ops == ["db", "db"]

      # Verify child spans have detailed data (like SQL queries)
      [span1, span2] = transaction.spans
      assert span1.description =~ "INSERT INTO"
      assert span2.description =~ "INSERT INTO"
      assert span1.data["db.system"] == :postgresql
      assert span2.data["db.system"] == :postgresql
      assert span1.data["db.statement"] =~ "INSERT INTO users"
      assert span2.data["db.statement"] =~ "INSERT INTO notifications"

      # Verify all spans share the same trace ID (from the external parent)
      trace_id = transaction.contexts.trace.trace_id

      Enum.each(transaction.spans, fn span ->
        assert span.trace_id == trace_id
      end)

      # The transaction should have the external parent's trace ID
      assert transaction.contexts.trace.trace_id ==
               "1234567890abcdef1234567890abcdef"
    end

    @tag span_storage: true
    test "cleans up HTTP server span and children after sending distributed trace transaction", %{
      table_name: table_name
    } do
      put_test_config(environment_name: "test", traces_sample_rate: 1.0)

      Sentry.Test.start_collecting_sentry_reports()

      # Simulate an incoming HTTP request with an external parent span ID (from browser/client)
      external_trace_id = 0x1234567890ABCDEF1234567890ABCDEF
      external_parent_span_id = 0xABCDEF1234567890

      remote_parent = :otel_tracer.from_remote_span(external_trace_id, external_parent_span_id, 1)
      ctx = Tracer.set_current_span(:otel_ctx.new(), remote_parent)

      # Start an HTTP server span with the remote parent context
      Tracer.with_span ctx, "POST /api/users", %{
        kind: :server,
        attributes: %{
          HTTPAttributes.http_request_method() => :POST,
          URLAttributes.url_path() => "/api/users"
        }
      } do
        # Simulate child spans (database queries, etc.)
        Tracer.with_span "db.query:users", %{
          kind: :client,
          attributes: %{
            "db.system" => :postgresql,
            "db.statement" => "INSERT INTO users (name) VALUES ($1)"
          }
        } do
          Process.sleep(10)
        end
      end

      # Should capture the HTTP request span as a transaction
      assert [%Sentry.Transaction{} = transaction] = Sentry.Test.pop_sentry_transactions()

      # Verify the HTTP server span was removed from storage
      # (even though it was stored as a child span due to having a remote parent)
      http_server_span_id = transaction.contexts.trace.span_id
      remote_parent_span_id_str = "abcdef1234567890"

      # The HTTP server span should not exist in storage anymore
      assert SpanStorage.get_root_span(http_server_span_id, table_name: table_name) == nil

      # Check that it was also removed from child spans storage
      # We can't directly check if a specific child was removed, but we can verify
      # that get_child_spans for the remote parent returns empty (or doesn't include our span)
      remaining_children =
        SpanStorage.get_child_spans(remote_parent_span_id_str, table_name: table_name)

      refute Enum.any?(remaining_children, fn span -> span.span_id == http_server_span_id end)

      # Verify child spans of the HTTP server span were also removed
      assert [] == SpanStorage.get_child_spans(http_server_span_id, table_name: table_name)
    end
  end

  describe "get_op_description/1" do
    @tag span_storage: true
    test "HTTP server span with url.path includes path in description" do
      put_test_config(environment_name: "test", traces_sample_rate: 1.0)

      Sentry.Test.start_collecting_sentry_reports()

      Tracer.with_span "GET /api/users", %{
        kind: :server,
        attributes: %{
          HTTPAttributes.http_request_method() => :GET,
          URLAttributes.url_path() => "/api/users"
        }
      } do
        Process.sleep(1)
      end

      assert [%Sentry.Transaction{} = transaction] = Sentry.Test.pop_sentry_transactions()

      assert transaction.contexts.trace.op == "http.server"
      assert transaction.contexts.trace.description == "GET /api/users"
    end

    @tag span_storage: true
    test "HTTP server span without url.path uses only method in description" do
      put_test_config(environment_name: "test", traces_sample_rate: 1.0)

      Sentry.Test.start_collecting_sentry_reports()

      Tracer.with_span "GET", %{
        kind: :server,
        attributes: %{
          HTTPAttributes.http_request_method() => :GET
        }
      } do
        Process.sleep(1)
      end

      assert [%Sentry.Transaction{} = transaction] = Sentry.Test.pop_sentry_transactions()

      assert transaction.contexts.trace.op == "http.server"
      assert transaction.contexts.trace.description == "GET"
    end

    @tag span_storage: true
    test "HTTP client span with url.path includes path in description" do
      put_test_config(environment_name: "test", traces_sample_rate: 1.0)

      Sentry.Test.start_collecting_sentry_reports()

      Tracer.with_span "GET /external/api", %{
        kind: :client,
        attributes: %{
          HTTPAttributes.http_request_method() => :GET,
          URLAttributes.url_path() => "/external/api"
        }
      } do
        Process.sleep(1)
      end

      assert [%Sentry.Transaction{} = transaction] = Sentry.Test.pop_sentry_transactions()

      assert transaction.contexts.trace.op == "http.client"
      assert transaction.contexts.trace.description == "GET /external/api"
    end

    @tag span_storage: true
    test "HTTP server span with client.address includes address in description" do
      put_test_config(environment_name: "test", traces_sample_rate: 1.0)

      Sentry.Test.start_collecting_sentry_reports()

      Tracer.with_span "POST /api/login", %{
        kind: :server,
        attributes: %{
          HTTPAttributes.http_request_method() => :POST,
          URLAttributes.url_path() => "/api/login",
          ClientAttributes.client_address() => "192.168.1.100"
        }
      } do
        Process.sleep(1)
      end

      assert [%Sentry.Transaction{} = transaction] = Sentry.Test.pop_sentry_transactions()

      assert transaction.contexts.trace.op == "http.server"
      assert transaction.contexts.trace.description == "POST /api/login from 192.168.1.100"
    end

    @tag span_storage: true
    test "database span uses db op and query as description" do
      put_test_config(environment_name: "test", traces_sample_rate: 1.0)

      Sentry.Test.start_collecting_sentry_reports()

      Tracer.with_span "SELECT users", %{
        kind: :client,
        attributes: %{
          DBAttributes.db_system() => :postgresql,
          "db.statement" => "SELECT * FROM users WHERE id = $1"
        }
      } do
        Process.sleep(1)
      end

      assert [%Sentry.Transaction{} = transaction] = Sentry.Test.pop_sentry_transactions()

      assert transaction.contexts.trace.op == "db"
      assert transaction.contexts.trace.description == "SELECT * FROM users WHERE id = $1"
    end

    @tag span_storage: true
    test "database span without statement has nil description" do
      put_test_config(environment_name: "test", traces_sample_rate: 1.0)

      Sentry.Test.start_collecting_sentry_reports()

      Tracer.with_span "db.connect", %{
        kind: :client,
        attributes: %{
          DBAttributes.db_system() => :postgresql
        }
      } do
        Process.sleep(1)
      end

      assert [%Sentry.Transaction{} = transaction] = Sentry.Test.pop_sentry_transactions()

      assert transaction.contexts.trace.op == "db"
      assert transaction.contexts.trace.description == nil
    end

    @tag span_storage: true
    test "Oban span uses queue.process op and worker as description" do
      put_test_config(environment_name: "test", traces_sample_rate: 1.0)

      Sentry.Test.start_collecting_sentry_reports()

      Tracer.with_span "MyApp.Workers.EmailWorker process", %{
        kind: :consumer,
        attributes: %{
          MessagingAttributes.messaging_system() => :oban,
          "oban.job.worker" => "MyApp.Workers.EmailWorker"
        }
      } do
        Process.sleep(1)
      end

      assert [%Sentry.Transaction{} = transaction] = Sentry.Test.pop_sentry_transactions()

      assert transaction.contexts.trace.op == "queue.process"
      assert transaction.contexts.trace.description == "MyApp.Workers.EmailWorker"
      # Also verify transaction name uses worker name for Oban spans
      assert transaction.transaction == "MyApp.Workers.EmailWorker"
    end

    @tag span_storage: true
    test "generic span uses span name for both op and description" do
      put_test_config(environment_name: "test", traces_sample_rate: 1.0)

      Sentry.Test.start_collecting_sentry_reports()

      Tracer.with_span "custom_operation" do
        Process.sleep(1)
      end

      assert [%Sentry.Transaction{} = transaction] = Sentry.Test.pop_sentry_transactions()

      assert transaction.contexts.trace.op == "custom_operation"
      assert transaction.contexts.trace.description == "custom_operation"
    end

    @tag span_storage: true
    test "child HTTP span has correct op and description" do
      put_test_config(environment_name: "test", traces_sample_rate: 1.0)

      Sentry.Test.start_collecting_sentry_reports()

      Tracer.with_span "parent_operation" do
        Tracer.with_span "GET /external/service", %{
          kind: :client,
          attributes: %{
            HTTPAttributes.http_request_method() => :GET,
            URLAttributes.url_path() => "/external/service"
          }
        } do
          Process.sleep(1)
        end
      end

      assert [%Sentry.Transaction{} = transaction] = Sentry.Test.pop_sentry_transactions()

      assert length(transaction.spans) == 1
      [child_span] = transaction.spans

      assert child_span.op == "http.client"
      assert child_span.description == "GET /external/service"
    end

    @tag span_storage: true
    test "child database span has correct op and description" do
      put_test_config(environment_name: "test", traces_sample_rate: 1.0)

      Sentry.Test.start_collecting_sentry_reports()

      Tracer.with_span "parent_operation" do
        Tracer.with_span "db.query", %{
          kind: :client,
          attributes: %{
            DBAttributes.db_system() => :mysql,
            "db.statement" => "INSERT INTO orders (user_id) VALUES (?)"
          }
        } do
          Process.sleep(1)
        end
      end

      assert [%Sentry.Transaction{} = transaction] = Sentry.Test.pop_sentry_transactions()

      assert length(transaction.spans) == 1
      [child_span] = transaction.spans

      assert child_span.op == "db"
      assert child_span.description == "INSERT INTO orders (user_id) VALUES (?)"
    end
  end
end
