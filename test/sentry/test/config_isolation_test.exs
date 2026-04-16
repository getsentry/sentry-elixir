defmodule Sentry.Test.ConfigIsolationTest do
  use Sentry.Case, async: true

  import Sentry.TestHelpers

  alias Sentry.Test.Scope

  defmodule AncestorProbe do
    use GenServer

    def start_link(report_to), do: GenServer.start_link(__MODULE__, report_to)

    @impl true
    def init(report_to) do
      send(report_to, {:resolved, Sentry.Config.environment_name()})
      {:ok, []}
    end
  end

  # Async overrides set via `put_test_config/1` must not leak across sibling
  # tests when resolved through the caller / ancestor chain — the precise
  # resolution strategies (callers → allow → ancestors) are responsible for
  # routing each supervised or spawned process to the correct scope.
  describe "overrides route correctly through caller and ancestor chains" do
    test "direct lookup on the test process" do
      put_test_config(environment_name: "iso_a")
      Process.sleep(10)
      assert Sentry.Config.environment_name() == "iso_a"
    end

    test "same key, different value (sibling test)" do
      put_test_config(environment_name: "iso_b")
      Process.sleep(10)
      assert Sentry.Config.environment_name() == "iso_b"
    end

    test "ancestor walk resolves override from a start_supervised child" do
      put_test_config(environment_name: "iso_supervised")

      {:ok, _pid} = start_supervised({AncestorProbe, self()})

      assert_receive {:resolved, "iso_supervised"}, 1_000
    end

    @tag :otp_25_plus
    test "parent-pid walk resolves override from a spawn_monitor child" do
      put_test_config(environment_name: "iso_spawn")

      me = self()

      {_pid, ref} =
        spawn_monitor(fn ->
          send(me, {:resolved, Sentry.Config.environment_name()})
        end)

      assert_receive {:resolved, "iso_spawn"}, 1_000
      assert_receive {:DOWN, ^ref, :process, _pid, _reason}
    end

    # A process with neither $callers nor $ancestors linking back to the
    # test, and which isn't in any scope's allowed_pids set, resolves to
    # :default. This is the guarantee that keeps async tests safe: a stray
    # process cannot accidentally latch onto whatever test happens to be
    # active. Globals like :logger are covered by the auto-allow in put/1,
    # not by an implicit single-active fallback.
    test "orphan process with no caller/ancestor/allow link resolves to :default" do
      put_test_config(environment_name: "iso_orphan_test")

      me = self()

      spawn(fn ->
        Process.delete(:"$callers")
        Process.delete(:"$ancestors")

        spawn(fn ->
          send(me, {:resolved, Sentry.Config.environment_name()})
        end)
      end)

      assert_receive {:resolved, resolved}, 1_000
      assert resolved != "iso_orphan_test"
    end

    # put/1 auto-allows :logger, :logger_sup and Sentry.Supervisor onto the
    # calling scope so Sentry.LoggerHandler resolves per-test config from
    # log events that fire in the global :logger process. Whether each
    # specific pid lands in *this* scope's allowed_pids depends on the
    # async race with sibling tests (soft_allow is a no-op when a live peer
    # scope already claimed a global). Routing correctness is covered by
    # the logger_handler_test suites passing without explicit allow/2.
    # Here we just verify the soft_allow primitive directly against an
    # isolated pid that no concurrent test can race us for.
    test "Registry.soft_allow/2 claims a free pid and skips when another scope owns it" do
      probe = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> Process.exit(probe, :kill) end)

      me = self()
      put_test_config(environment_name: "iso_soft_allow")

      Sentry.Test.Scope.Registry.soft_allow(self(), probe)
      assert Sentry.Test.Scope.Registry.lookup_allow_owner(probe) == me

      # A peer scope attempting to soft_allow the same pid is a no-op.
      peer =
        spawn(fn ->
          put_test_config(environment_name: "iso_soft_allow_peer")
          Sentry.Test.Scope.Registry.soft_allow(self(), probe)

          send(
            me,
            {:peer_owns_probe?, Sentry.Test.Scope.Registry.lookup_allow_owner(probe) == self()}
          )

          receive do
            :exit -> :ok
          end
        end)

      assert_receive {:peer_owns_probe?, false}, 1_000
      send(peer, :exit)
    end
  end

  # Explicit allow/2 should surface conflicts loudly. The auto-allow on the
  # global pids in put/1 is separately soft (see the Registry.soft_allow/2
  # docs) so concurrent async tests don't race on shared globals.
  describe "allow/2 concurrent claims" do
    test "second owner raises while first is live; succeeds after first exits" do
      shared_pid = spawn(fn -> Process.sleep(:infinity) end)
      parent = self()

      owner_a =
        spawn(fn ->
          Sentry.Test.Config.allow(self(), shared_pid)
          send(parent, :claimed)

          receive do
            :exit -> :ok
          end
        end)

      assert_receive :claimed, 1_000

      assert_raise Scope.AllowConflictError, fn ->
        Sentry.Test.Config.allow(self(), shared_pid)
      end

      ref = Process.monitor(owner_a)
      send(owner_a, :exit)
      assert_receive {:DOWN, ^ref, :process, _pid, _reason}, 1_000

      # owner_a's scope is filtered out of list_active/0 via Process.alive?
      # once it exits, so re-claiming under a new owner succeeds.
      assert :ok = Sentry.Test.Config.allow(self(), shared_pid)

      Process.exit(shared_pid, :kill)
    end

    test "same owner re-allowing the same pid is idempotent" do
      shared_pid = spawn(fn -> Process.sleep(:infinity) end)

      assert :ok = Sentry.Test.Config.allow(self(), shared_pid)
      assert :ok = Sentry.Test.Config.allow(self(), shared_pid)

      Process.exit(shared_pid, :kill)
    end

    test "allow/2 with nil pid is a no-op" do
      assert :ok = Sentry.Test.Config.allow(self(), nil)
    end
  end
end
