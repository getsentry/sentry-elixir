defmodule Sentry.Integrations.Phoenix.ObanTest do
  use PhoenixAppWeb.ConnCase, async: false
  use Oban.Testing, repo: PhoenixApp.Repo

  import ExUnit.CaptureLog
  import Sentry.TestHelpers
  
  require OpenTelemetry.Tracer

  alias Sentry.Integrations.Oban.ErrorReporter

  setup do
    bypass = Bypass.open()
    put_test_config(dsn: "http://public:secret@localhost:#{bypass.port}/1", traces_sample_rate: 1.0, send_result: :sync)

    %{bypass: bypass}
  end

  defmodule TestWorker do
    use Oban.Worker

    @impl Oban.Worker
    def perform(_args) do
      :timer.sleep(100)
    end
  end

  defmodule FailingWorker do
    use Oban.Worker, max_attempts: 3

    @impl Oban.Worker
    def perform(%Oban.Job{args: %{"should_fail" => true}}) do
      raise "intentional failure for testing"
    end

    def perform(_job), do: :ok
  end

  defmodule WorkerWithDatabaseQuery do
    use Oban.Worker

    @impl Oban.Worker
    def perform(%Oban.Job{}) do
      # Execute a database query to generate child spans
      PhoenixApp.Repo.query("SELECT 1")
      :ok
    end
  end

  test "captures Oban worker execution as transaction", %{bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/api/1/envelope/", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert [{headers, transaction_body}] = decode_envelope!(body)

      assert headers["type"] == "transaction"
      assert transaction_body["transaction"] == "Sentry.Integrations.Phoenix.ObanTest.TestWorker"
      
      trace = transaction_body["contexts"]["trace"]
      assert trace["origin"] == "opentelemetry_oban"
      assert trace["op"] == "queue.process"
      assert trace["data"]["oban.job.job_id"]
      assert trace["data"]["messaging.destination.name"] == "default"
      assert trace["data"]["oban.job.attempt"] == 1

      assert transaction_body["spans"] == []

      Plug.Conn.send_resp(conn, 200, ~s<{"id": "340"}>)
    end)

    :ok = perform_job(TestWorker, %{test: "args"})
  end

  test "captures Oban worker with trace links", %{bypass: bypass} do
    # This test verifies that when an Oban job is inserted within an active trace,
    # the consumer span has links back to the producer span.
    test_pid = self()

    Bypass.stub(bypass, "POST", "/api/1/envelope/", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      for {headers, body_json} <- decode_envelope!(body) do
        send(test_pid, {headers["type"], body_json})
      end

      Plug.Conn.send_resp(conn, 200, ~s<{"id": "340"}>)
    end)

    # Insert within an active span so trace context is propagated into job metadata
    OpenTelemetry.Tracer.with_span "test.request" do
      {:ok, _job} =
        %{test: "with_links"}
        |> TestWorker.new()
        |> OpentelemetryOban.insert()
    end

    # Drain the queue to execute the job
    Oban.drain_queue(queue: :default)

    # Multiple transactions are sent (test.request, DB queries, Oban consumer),
    # so we need to find the Oban consumer transaction specifically
    oban_tx = receive_oban_transaction()

    trace = oban_tx["contexts"]["trace"]
    assert trace["op"] == "queue.process"
    assert trace["origin"] == "opentelemetry_oban"

    # Verify span links are present and properly formatted
    assert is_list(trace["links"]), "expected trace links to be present"
    assert length(trace["links"]) > 0, "expected at least one span link"

    for link <- trace["links"] do
      assert is_binary(link["span_id"])
      assert is_binary(link["trace_id"])
      assert String.match?(link["span_id"], ~r/^[a-f0-9]{16}$/)
      assert String.match?(link["trace_id"], ~r/^[a-f0-9]{32}$/)
    end
  end

  test "captures Oban worker with child spans", %{bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/api/1/envelope/", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert [{headers, transaction_body}] = decode_envelope!(body)

      assert headers["type"] == "transaction"
      assert transaction_body["transaction"] ==
               "Sentry.Integrations.Phoenix.ObanTest.WorkerWithDatabaseQuery"

      # Should have child spans from the database query
      assert length(transaction_body["spans"]) > 0

      # Verify at least one db span exists
      assert Enum.any?(transaction_body["spans"], fn span ->
               span["op"] == "db"
             end)

      Plug.Conn.send_resp(conn, 200, ~s<{"id": "340"}>)
    end)

    :ok = perform_job(WorkerWithDatabaseQuery, %{})
  end

  defp receive_oban_transaction do
    receive do
      {"transaction", tx} ->
        if tx["contexts"]["trace"]["origin"] == "opentelemetry_oban" do
          tx
        else
          receive_oban_transaction()
        end
    after
      2000 -> flunk("expected an Oban consumer transaction")
    end
  end

  describe "should_report_error_callback config" do
    setup %{bypass: bypass} do
      :telemetry.detach(ErrorReporter)

      on_exit(fn ->
        _ = :telemetry.detach(ErrorReporter)
        ErrorReporter.attach([])
      end)

      %{bypass: bypass}
    end

    test "skips error reporting when callback returns false", %{bypass: bypass} do
      test_pid = self()

      # Allow transaction envelopes through but assert no error events are sent
      Bypass.stub(bypass, "POST", "/api/1/envelope/", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        items = decode_envelope!(body)

        for {headers, _body} <- items do
          assert headers["type"] != "event",
                 "Should not send error events when callback returns false"
        end

        Plug.Conn.send_resp(conn, 200, ~s<{"id": "340"}>)
      end)

      ErrorReporter.attach(
        should_report_error_callback: fn worker, job ->
          send(test_pid, {:callback_invoked, worker, job})
          false
        end
      )

      {:ok, _job} =
        %{"should_fail" => true}
        |> FailingWorker.new()
        |> Oban.insert()

      assert %{failure: 1} = Oban.drain_queue(queue: :default)

      assert_receive {:callback_invoked, worker, received_job}
      assert worker == FailingWorker
      assert %Oban.Job{} = received_job
      assert received_job.args == %{"should_fail" => true}
    end

    test "reports error when callback returns true", %{bypass: bypass} do
      test_pid = self()

      Bypass.stub(bypass, "POST", "/api/1/envelope/", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        for {headers, item_body} <- decode_envelope!(body) do
          if headers["type"] == "event" do
            send(test_pid, {:error_event, item_body})
          end
        end

        Plug.Conn.send_resp(conn, 200, ~s<{"id": "340"}>)
      end)

      ErrorReporter.attach(
        should_report_error_callback: fn worker, job ->
          send(test_pid, {:callback_invoked, worker, job})
          true
        end
      )

      {:ok, _job} =
        %{"should_fail" => true}
        |> FailingWorker.new()
        |> Oban.insert()

      assert %{failure: 1} = Oban.drain_queue(queue: :default)

      assert_receive {:callback_invoked, _worker, _job}

      assert_receive {:error_event, event_body}
      exception = event_body["exception"] |> List.first()
      assert exception["type"] == "RuntimeError"
      assert exception["value"] == "intentional failure for testing"
      assert event_body["tags"]["oban_worker"] ==
               "Sentry.Integrations.Phoenix.ObanTest.FailingWorker"
    end

    test "callback receives worker module and full job struct", %{bypass: bypass} do
      test_pid = self()

      Bypass.stub(bypass, "POST", "/api/1/envelope/", fn conn ->
        {:ok, _body, conn} = Plug.Conn.read_body(conn)
        Plug.Conn.send_resp(conn, 200, ~s<{"id": "340"}>)
      end)

      ErrorReporter.attach(
        should_report_error_callback: fn worker, job ->
          send(test_pid, {:callback_args, worker, job})
          true
        end
      )

      {:ok, _job} =
        %{"should_fail" => true, "user_id" => 123}
        |> FailingWorker.new()
        |> Oban.insert()

      Oban.drain_queue(queue: :default)

      assert_receive {:callback_args, worker, job}

      assert worker == FailingWorker
      assert is_atom(worker)

      assert %Oban.Job{} = job
      assert job.args == %{"should_fail" => true, "user_id" => 123}
      assert job.worker == "Sentry.Integrations.Phoenix.ObanTest.FailingWorker"
      assert job.queue == "default"
      assert job.max_attempts == 3
      assert is_integer(job.attempt)
      assert is_integer(job.id)
    end

    test "callback can make decisions based on attempt number", %{bypass: bypass} do
      test_pid = self()

      # Allow transaction envelopes through but assert no error events are sent
      Bypass.stub(bypass, "POST", "/api/1/envelope/", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        items = decode_envelope!(body)

        for {headers, _body} <- items do
          assert headers["type"] != "event",
                 "Should not send error events when callback returns false"
        end

        Plug.Conn.send_resp(conn, 200, ~s<{"id": "340"}>)
      end)

      ErrorReporter.attach(
        should_report_error_callback: fn _worker, job ->
          should_report = job.attempt >= job.max_attempts
          send(test_pid, {:report_decision, job.attempt, job.max_attempts, should_report})
          should_report
        end
      )

      {:ok, _job} =
        %{"should_fail" => true}
        |> FailingWorker.new()
        |> Oban.insert()

      Oban.drain_queue(queue: :default)

      assert_receive {:report_decision, attempt, max_attempts, should_report}
      assert attempt == 1
      assert max_attempts == 3
      assert should_report == false
    end

    test "handles callback errors gracefully and defaults to reporting", %{bypass: bypass} do
      test_pid = self()

      Bypass.stub(bypass, "POST", "/api/1/envelope/", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        for {headers, item_body} <- decode_envelope!(body) do
          if headers["type"] == "event" do
            send(test_pid, {:error_event, item_body})
          end
        end

        Plug.Conn.send_resp(conn, 200, ~s<{"id": "340"}>)
      end)

      log =
        capture_log(fn ->
          ErrorReporter.attach(
            should_report_error_callback: fn _worker, _job ->
              raise "callback crashed!"
            end
          )

          {:ok, _job} =
            %{"should_fail" => true}
            |> FailingWorker.new()
            |> Oban.insert()

          Oban.drain_queue(queue: :default)
        end)

      assert log =~ "should_report_error_callback failed"
      assert log =~ "FailingWorker"
      assert log =~ "callback crashed!"

      assert_receive {:error_event, event_body}
      exception = event_body["exception"] |> List.first()
      assert exception["type"] == "RuntimeError"
      assert exception["value"] == "intentional failure for testing"
    end

    test "reports error when no callback is configured", %{bypass: bypass} do
      test_pid = self()

      Bypass.stub(bypass, "POST", "/api/1/envelope/", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        for {headers, item_body} <- decode_envelope!(body) do
          if headers["type"] == "event" do
            send(test_pid, {:error_event, item_body})
          end
        end

        Plug.Conn.send_resp(conn, 200, ~s<{"id": "340"}>)
      end)

      ErrorReporter.attach([])

      {:ok, _job} =
        %{"should_fail" => true}
        |> FailingWorker.new()
        |> Oban.insert()

      Oban.drain_queue(queue: :default)

      assert_receive {:error_event, event_body}
      exception = event_body["exception"] |> List.first()
      assert exception["type"] == "RuntimeError"
      assert exception["value"] == "intentional failure for testing"
    end

    test "callback can filter based on worker type", %{bypass: bypass} do
      test_pid = self()

      # Allow transaction envelopes through but assert no error events are sent
      Bypass.stub(bypass, "POST", "/api/1/envelope/", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        items = decode_envelope!(body)

        for {headers, _body} <- items do
          assert headers["type"] != "event",
                 "Should not send error events when callback returns false"
        end

        Plug.Conn.send_resp(conn, 200, ~s<{"id": "340"}>)
      end)

      ErrorReporter.attach(
        should_report_error_callback: fn worker, _job ->
          should_report = worker != FailingWorker
          send(test_pid, {:worker_check, worker, should_report})
          should_report
        end
      )

      {:ok, _job} =
        %{"should_fail" => true}
        |> FailingWorker.new()
        |> Oban.insert()

      Oban.drain_queue(queue: :default)

      assert_receive {:worker_check, FailingWorker, false}
    end

    test "callback receives nil and logs warning for non-existent worker module", %{bypass: bypass} do
      test_pid = self()

      Bypass.stub(bypass, "POST", "/api/1/envelope/", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        for {headers, item_body} <- decode_envelope!(body) do
          if headers["type"] == "event" do
            send(test_pid, {:error_event, item_body})
          end
        end

        Plug.Conn.send_resp(conn, 200, ~s<{"id": "340"}>)
      end)

      log =
        capture_log(fn ->
          ErrorReporter.attach(
            should_report_error_callback: fn worker, job ->
              send(test_pid, {:callback_with_unknown_worker, worker, job})
              true
            end
          )

          job = %Oban.Job{
            id: 999,
            args: %{"test" => true},
            worker: "NonExistent.Worker.Module",
            queue: "default",
            state: "executing",
            attempt: 1,
            max_attempts: 3
          }

          :telemetry.execute(
            [:oban, :job, :exception],
            %{duration: 1000},
            %{
              job: job,
              kind: :error,
              reason: %RuntimeError{message: "worker failed"},
              stacktrace: []
            }
          )
        end)

      assert log =~ "Could not resolve Oban worker module from string"
      assert log =~ "NonExistent.Worker.Module"

      assert_receive {:callback_with_unknown_worker, worker, received_job}
      assert worker == nil
      assert received_job.worker == "NonExistent.Worker.Module"

      assert_receive {:error_event, event_body}
      assert event_body["tags"]["oban_worker"] == "NonExistent.Worker.Module"
    end
  end
end
