defmodule Sentry.Test.Registry do
  @moduledoc false

  use GenServer

  require Logger

  # Bypass and Plug.Conn may not be available at compile time (optional deps).
  @compile {:no_warn_undefined, [Bypass, Bypass.Instance, Bypass.Supervisor, Plug.Conn]}

  @table :sentry_test_collectors

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link([] = _opts) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @doc false
  @spec default_dsn :: String.t() | nil
  def default_dsn do
    :persistent_term.get(:sentry_test_default_bypass_dsn, nil)
  end

  @impl true
  def init(nil) do
    _table = :ets.new(@table, [:named_table, :public, :set])
    maybe_start_default_bypass()
    {:ok, :no_state}
  end

  # Starts a global Bypass instance that acts as a silent HTTP sink for all tests.
  # This ensures every test has a valid DSN even without calling setup_sentry/1,
  # preserving backward compatibility where capture_* returns {:ok, ""}.
  #
  # In test mode we always override any externally-configured DSN (for example
  # one leaking in from the SENTRY_DSN environment variable), so that running
  # the test suite can never accidentally ship synthetic events to a real
  # Sentry endpoint. When an override happens, we emit a Logger.warning so the
  # developer sees exactly what is being replaced and why.
  defp maybe_start_default_bypass do
    if Code.ensure_loaded?(Bypass) do
      {:ok, _apps} = Application.ensure_all_started(:bypass)

      {:ok, pid} =
        DynamicSupervisor.start_child(
          Bypass.Supervisor,
          Bypass.Instance.child_spec([])
        )

      port = Bypass.Instance.call(pid, :port)
      bypass = struct!(Bypass, pid: pid, port: port)

      # Stub with empty ID to match master's {:ok, ""} return value
      Bypass.stub(bypass, "POST", "/api/1/envelope/", fn conn ->
        Plug.Conn.resp(conn, 200, ~s<{"id": ""}>)
      end)

      dsn_string = "http://public:secret@localhost:#{port}/1"
      maybe_warn_about_dsn_override(dsn_string)

      :persistent_term.put(:sentry_test_default_bypass_dsn, dsn_string)
      Sentry.put_config(:dsn, dsn_string)
    end
  end

  @doc false
  @spec maybe_warn_about_dsn_override(String.t()) :: :ok
  def maybe_warn_about_dsn_override(new_dsn) do
    case Sentry.Config.dsn() do
      %Sentry.DSN{original_dsn: existing} ->
        Logger.warning("""
        [Sentry] test_mode is enabled but a DSN was already configured \
        (#{inspect(existing)}). Overriding it with the local Bypass sink at \
        #{new_dsn} to prevent test events from being sent to a real Sentry \
        endpoint. If this DSN came from the SENTRY_DSN environment variable, \
        unset it for test runs or set :dsn explicitly in your test config.\
        """)

        :ok

      nil ->
        :ok

      _other ->
        :ok
    end
  end
end
