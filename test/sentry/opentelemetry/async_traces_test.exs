defmodule Sentry.Opentelemetry.AsyncTracesTest do
  # Asserts only on reported envelopes, never on span-processing internals,
  # so this coverage holds across changes to how spans are processed.

  use Sentry.Case, async: false

  require OpenTelemetry.Tracer, as: Tracer

  import ExUnit.CaptureLog
  import Sentry.Test.Assertions
  import Sentry.TestHelpers

  setup do
    setup_bypass()
  end

  describe "spans that start after their trace's root span has ended" do
    test "are reported as a follow-up transaction in the same trace", %{bypass: bypass} do
      put_test_config(environment_name: "test", traces_sample_rate: 1.0)
      ref = setup_bypass_envelope_collector(bypass)

      parent_ctx =
        Tracer.with_span "sync_root" do
          :otel_ctx.get_current()
        end

      Task.async(fn ->
        Process.sleep(25)

        token = :otel_ctx.attach(parent_ctx)

        try do
          Tracer.with_span "async_parent" do
            Tracer.with_span "async_child" do
              Process.sleep(1)
            end
          end
        after
          :otel_ctx.detach(token)
        end
      end)
      |> Task.await()

      transactions = collect_sentry_transactions(ref, 2, timeout: 1000)

      root_tx = find_sentry_report!(transactions, transaction: "sync_root")
      async_tx = find_sentry_report!(transactions, transaction: "async_parent")

      root_trace = root_tx["contexts"]["trace"]
      async_trace = async_tx["contexts"]["trace"]

      assert async_trace["trace_id"] == root_trace["trace_id"]
      assert async_trace["parent_span_id"] == root_trace["span_id"]
      assert async_trace["data"]["sentry.parent_span_already_sent"] == true

      assert [child_span] = async_tx["spans"]
      assert child_span["op"] == "async_child"
      assert child_span["parent_span_id"] == async_trace["span_id"]
      assert child_span["trace_id"] == root_trace["trace_id"]
    end
  end

  describe "spans that continue a trace from a nested span of a sent transaction" do
    test "are reported as a follow-up transaction in the same trace", %{bypass: bypass} do
      put_test_config(environment_name: "test", traces_sample_rate: 1.0)
      ref = setup_bypass_envelope_collector(bypass)

      inner_ctx =
        Tracer.with_span "root" do
          Tracer.with_span "level_1" do
            Tracer.with_span "level_2" do
              :otel_ctx.get_current()
            end
          end
        end

      [root_tx] = collect_sentry_transactions(ref, 1)
      assert root_tx["transaction"] == "root"

      level_2_span = Enum.find(root_tx["spans"], &(&1["op"] == "level_2"))
      assert level_2_span

      Task.async(fn ->
        token = :otel_ctx.attach(inner_ctx)

        try do
          Tracer.with_span "late_async_span" do
            Process.sleep(1)
          end
        after
          :otel_ctx.detach(token)
        end
      end)
      |> Task.await()

      assert [late_tx] = collect_sentry_transactions(ref, 1),
             "no follow-up transaction was reported for the late span"

      assert late_tx["transaction"] == "late_async_span"

      late_trace = late_tx["contexts"]["trace"]

      assert late_trace["trace_id"] == root_tx["contexts"]["trace"]["trace_id"]
      assert late_trace["parent_span_id"] == level_2_span["span_id"]
      assert late_trace["data"]["sentry.parent_span_already_sent"] == true
    end
  end

  describe "a child span that is still running when the transaction root ends" do
    test "is not reported without an end timestamp", %{bypass: bypass} do
      put_test_config(environment_name: "test", traces_sample_rate: 1.0)
      ref = setup_bypass_envelope_collector(bypass)

      test_pid = self()

      task =
        Tracer.with_span "sync_root" do
          ctx = :otel_ctx.get_current()

          task =
            Task.async(fn ->
              token = :otel_ctx.attach(ctx)

              try do
                Tracer.with_span "in_flight_child" do
                  send(test_pid, :child_started)

                  receive do
                    :finish_child -> :ok
                  end
                end
              after
                :otel_ctx.detach(token)
              end
            end)

          assert_receive :child_started, 1000
          task
        end

      [root_tx] = collect_sentry_transactions(ref, 1)
      assert root_tx["transaction"] == "sync_root"

      assert Enum.all?(root_tx["spans"], & &1["timestamp"]),
             "transaction contains spans without an end timestamp: " <>
               inspect(root_tx["spans"])

      send(task.pid, :finish_child)
      Task.await(task)
    end

    test "is reported as a follow-up transaction once it finishes", %{bypass: bypass} do
      put_test_config(environment_name: "test", traces_sample_rate: 1.0)
      ref = setup_bypass_envelope_collector(bypass)

      test_pid = self()

      task =
        Tracer.with_span "sync_root" do
          ctx = :otel_ctx.get_current()

          task =
            Task.async(fn ->
              token = :otel_ctx.attach(ctx)

              try do
                Tracer.with_span "in_flight_child" do
                  send(test_pid, :child_started)

                  receive do
                    :finish_child -> :ok
                  end
                end
              after
                :otel_ctx.detach(token)
              end
            end)

          assert_receive :child_started, 1000
          task
        end

      [root_tx] = collect_sentry_transactions(ref, 1)
      assert root_tx["transaction"] == "sync_root"

      send(task.pid, :finish_child)
      Task.await(task)

      assert [child_tx] = collect_sentry_transactions(ref, 1),
             "no follow-up transaction was reported for the late-finishing child"

      assert child_tx["transaction"] == "in_flight_child"

      root_trace = root_tx["contexts"]["trace"]
      child_trace = child_tx["contexts"]["trace"]

      assert child_trace["trace_id"] == root_trace["trace_id"]
      assert child_trace["parent_span_id"] == root_trace["span_id"]
    end
  end

  describe "a child span that finishes while the root transaction is being sent" do
    test "is reported as a follow-up transaction", %{bypass: bypass} do
      put_test_config(environment_name: "test", traces_sample_rate: 1.0)

      test_pid = self()

      Bypass.stub(bypass, "POST", "/api/1/envelope/", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:envelope, body})

        if body =~ "sync_root" do
          send(test_pid, {:root_send_started, self()})

          receive do
            :release_root -> :ok
          end
        end

        Plug.Conn.resp(conn, 200, ~s<{"id": "#{Sentry.UUID.uuid4_hex()}"}>)
      end)

      root_task =
        Task.async(fn ->
          Tracer.with_span "sync_root" do
            send(test_pid, {:root_ctx, :otel_ctx.get_current()})

            receive do
              :end_root -> :ok
            end
          end
        end)

      assert_receive {:root_ctx, ctx}

      child_task =
        Task.async(fn ->
          token = :otel_ctx.attach(ctx)

          try do
            Tracer.with_span "late_child" do
              send(test_pid, :child_started)

              receive do
                :finish_child -> :ok
              end
            end
          after
            :otel_ctx.detach(token)
          end
        end)

      assert_receive :child_started
      send(root_task.pid, :end_root)
      assert_receive {:root_send_started, handler_pid}, 1000

      send(child_task.pid, :finish_child)
      Task.await(child_task)

      send(handler_pid, :release_root)
      Task.await(root_task)

      transactions = drain_transactions()

      root_tx = find_sentry_report!(transactions, transaction: "sync_root")
      child_tx = find_sentry_report!(transactions, transaction: "late_child")

      child_trace = child_tx["contexts"]["trace"]

      assert child_trace["trace_id"] == root_tx["contexts"]["trace"]["trace_id"]
      assert child_trace["parent_span_id"] == root_tx["contexts"]["trace"]["span_id"]
    end
  end

  describe "spans reported with the root transaction" do
    test "are not repeated in follow-up transactions", %{bypass: bypass} do
      put_test_config(environment_name: "test", traces_sample_rate: 1.0)
      ref = setup_bypass_envelope_collector(bypass)

      test_pid = self()

      task =
        Tracer.with_span "sync_root" do
          ctx = :otel_ctx.get_current()

          task =
            Task.async(fn ->
              token = :otel_ctx.attach(ctx)

              try do
                Tracer.with_span "async_parent" do
                  Tracer.with_span "finished_grandchild" do
                    :ok
                  end

                  send(test_pid, :grandchild_done)

                  receive do
                    :finish_parent -> :ok
                  end
                end
              after
                :otel_ctx.detach(token)
              end
            end)

          assert_receive :grandchild_done
          task
        end

      [root_tx] = collect_sentry_transactions(ref, 1)
      assert root_tx["transaction"] == "sync_root"

      root_span_descriptions = Enum.map(root_tx["spans"], & &1["description"])
      assert "finished_grandchild" in root_span_descriptions

      send(task.pid, :finish_parent)
      Task.await(task)

      [followup_tx] = collect_sentry_transactions(ref, 1)
      assert followup_tx["transaction"] == "async_parent"

      assert followup_tx["spans"] == [],
             "spans already reported with the root transaction were repeated: " <>
               inspect(followup_tx["spans"])
    end
  end

  describe "when the root transaction fails to send" do
    test "late spans are still reported as follow-up transactions", %{bypass: bypass} do
      put_test_config(environment_name: "test", traces_sample_rate: 1.0)

      test_pid = self()

      Bypass.stub(bypass, "POST", "/api/1/envelope/", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:envelope, body})

        if body =~ "sync_root" do
          Plug.Conn.resp(conn, 500, ~s<{"error": "internal"}>)
        else
          Plug.Conn.resp(conn, 200, ~s<{"id": "#{Sentry.UUID.uuid4_hex()}"}>)
        end
      end)

      log =
        capture_log(fn ->
          task =
            Tracer.with_span "sync_root" do
              ctx = :otel_ctx.get_current()

              task =
                Task.async(fn ->
                  token = :otel_ctx.attach(ctx)

                  try do
                    Tracer.with_span "late_child" do
                      send(test_pid, :child_started)

                      receive do
                        :finish_child -> :ok
                      end
                    end
                  after
                    :otel_ctx.detach(token)
                  end
                end)

              assert_receive :child_started
              task
            end

          send(task.pid, :finish_child)
          Task.await(task)
        end)

      assert log =~ "Failed to send transaction to Sentry"

      transactions = drain_transactions()

      root_tx = find_sentry_report!(transactions, transaction: "sync_root")
      child_tx = find_sentry_report!(transactions, transaction: "late_child")

      child_trace = child_tx["contexts"]["trace"]

      assert child_trace["trace_id"] == root_tx["contexts"]["trace"]["trace_id"]
      assert child_trace["parent_span_id"] == root_tx["contexts"]["trace"]["span_id"]
    end
  end

  defp drain_transactions(acc \\ []) do
    receive do
      {:envelope, body} -> drain_transactions([body | acc])
    after
      500 ->
        acc
        |> Enum.reverse()
        |> Enum.map(&decode_envelope!/1)
        |> extract_transactions()
    end
  end
end
